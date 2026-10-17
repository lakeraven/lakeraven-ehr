# frozen_string_literal: true

require "test_helper"
require "open3"
require "socket"
require "fileutils"
require "timeout"

# Contract for test/dummy/bin/demo (issue #543): refuse occupied ports without
# killing foreign processes; honor PORT for bind and printed URL.
class DemoScriptTest < ActiveSupport::TestCase
  DEMO_SCRIPT_SOURCE = File.expand_path("../dummy/bin/demo", __dir__)

  setup do
    @stub_bin = Dir.mktmpdir("demo_script_stub_bin_")
    @trees = []
    @port_holder_pids = []
    install_pg_isready_stub(@stub_bin)
  end

  teardown do
    @port_holder_pids.each { |pid| terminate_pid(pid) }
    @trees.each { |tree| FileUtils.remove_entry(tree) if tree && Dir.exist?(tree) }
    FileUtils.remove_entry(@stub_bin) if @stub_bin && Dir.exist?(@stub_bin)
  end

  test "refuses busy port without killing holder or starting rails" do
    skip "lsof not on PATH; required for port-holder detection" unless lsof_available?

    port = find_free_port
    holder_pid = spawn_port_holder(port)
    @port_holder_pids << holder_pid
    wait_for_port_listen(port, holder_pid)

    tree = build_demo_tree
    env = demo_env(tree[:rails_log], "PORT" => port.to_s)

    _stdout, stderr, status = run_demo(tree[:demo_path], env)

    refute_predicate status, :success?, "expected failure when port #{port} is busy"
    assert_includes stderr, port.to_s, "stderr should name the port"
    assert_match(/\b#{holder_pid}\b/, stderr, "stderr should identify the holder PID")
    assert_match(/PORT/i, stderr, "stderr should suggest choosing another PORT")

    assert_process_alive(holder_pid)
    refute rails_invoked?(tree[:rails_log]),
           "fake rails must not run when the port is already in use"
  end

  test "starts rails on free port from PORT with URL mentioning that port" do
    port = find_free_port
    tree = build_demo_tree
    env = demo_env(tree[:rails_log], "PORT" => port.to_s)

    stdout, _stderr, status = run_demo(tree[:demo_path], env)

    assert_predicate status, :success?
    assert_includes stdout, port.to_s, "stdout URL should mention PORT"

    argv, recorded_port = read_rails_invocation(tree[:rails_log])
    assert_includes argv, "server"
    assert_port_argv(argv, port)
    assert_equal port.to_s, recorded_port
  end

  test "defaults to port 3000 when PORT is unset" do
    skip "port 3000 is not free in this environment" unless port_free?(3000)

    tree = build_demo_tree
    env = demo_env(tree[:rails_log])
    env.delete("PORT")

    _stdout, _stderr, status = run_demo(tree[:demo_path], env)

    assert_predicate status, :success?

    argv, recorded_port = read_rails_invocation(tree[:rails_log])
    assert_port_argv(argv, 3000)
    assert_equal "3000", recorded_port
  end

  test "demo script source does not invoke kill on non-comment lines" do
    File.readlines(DEMO_SCRIPT_SOURCE).each_with_index do |line, index|
      next if line.strip.start_with?("#")

      assert_no_match(/\bkill\b/, line, "unexpected kill on line #{index + 1}: #{line.strip}")
    end
  end

  private

  def lsof_available?
    system("command -v lsof >/dev/null 2>&1")
  end

  def find_free_port
    server = TCPServer.new("127.0.0.1", 0)
    port = server.addr[1]
    server.close
    port
  end

  def port_free?(port)
    server = TCPServer.new("127.0.0.1", port)
    server.close
    true
  rescue Errno::EADDRINUSE, Errno::EACCES
    false
  end

  def spawn_port_holder(port)
    pid = Process.spawn(
      RbConfig.ruby,
      "-rsocket",
      "-e",
      'TCPServer.new("127.0.0.1", Integer(ARGV[0])); sleep',
      port.to_s,
      %i[out err] => "/dev/null"
    )
    pid
  end

  def wait_for_port_listen(port, holder_pid, timeout: 5)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    loop do
      raise "port holder #{holder_pid} exited early" unless process_alive?(holder_pid)

      return if port_free?(port) == false

      if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
        flunk "timed out waiting for holder to listen on port #{port}"
      end
      sleep 0.05
    end
  end

  def install_pg_isready_stub(stub_bin)
    path = File.join(stub_bin, "pg_isready")
    File.write(path, "#!/bin/sh\nexit 0\n")
    File.chmod(0o755, path)
  end

  def build_demo_tree
    root = Dir.mktmpdir("demo_script_tree_")
    @trees << root

    bin_dir = File.join(root, "bin")
    FileUtils.mkdir_p(bin_dir)
    FileUtils.mkdir_p(File.join(root, "tmp", "pids"))

    demo_path = File.join(bin_dir, "demo")
    FileUtils.cp(DEMO_SCRIPT_SOURCE, demo_path)
    File.chmod(0o755, demo_path)

    rails_log = File.join(root, "rails_invocation.log")
    rails_path = File.join(bin_dir, "rails")
    File.write(
      rails_path,
      <<~STUB
        #!/bin/sh
        log="${DEMO_TEST_RAILS_LOG:?}"
        {
          printf 'PORT=%s\\n' "${PORT:-}"
          printf '%s\\n' "$@"
        } > "$log"
        exit 0
      STUB
    )
    File.chmod(0o755, rails_path)

    { root: root, demo_path: demo_path, rails_log: rails_log }
  end

  def demo_env(rails_log, extra = {})
    path = "#{@stub_bin}:#{ENV.fetch('PATH', '')}"
    {
      "PATH" => path,
      "DEMO_TEST_RAILS_LOG" => rails_log
    }.merge(extra)
  end

  def run_demo(demo_path, env)
    Open3.capture3(env, demo_path)
  end

  def rails_invoked?(rails_log)
    File.exist?(rails_log) && !File.empty?(rails_log)
  end

  def read_rails_invocation(rails_log)
    assert rails_invoked?(rails_log), "expected fake rails to be invoked"

    lines = File.readlines(rails_log, chomp: true)
    port_line = lines.shift
    recorded_port = port_line.sub(/^PORT=/, "")
    argv = lines
    [argv, recorded_port]
  end

  def assert_port_argv(argv, port)
    port_str = port.to_s
    if (idx = argv.index("-p"))
      assert_equal port_str, argv[idx + 1]
    elsif (idx = argv.index("--port"))
      assert_equal port_str, argv[idx + 1]
    else
      flunk "expected rails server to be called with -p or --port #{port_str}, got: #{argv.inspect}"
    end
  end

  def assert_process_alive(pid)
    assert process_alive?(pid), "expected holder process #{pid} to still be running"
  end

  def process_alive?(pid)
    Process.kill(0, pid)
    true
  rescue Errno::ESRCH, Errno::EPERM
    false
  end

  def terminate_pid(pid)
    return unless pid

    Process.kill("TERM", pid)
    Timeout.timeout(2) { Process.wait(pid) }
  rescue Errno::ESRCH, Errno::ECHILD, Timeout::Error
    Process.kill("KILL", pid) rescue nil
  end
end
