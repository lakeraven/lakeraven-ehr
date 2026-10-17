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
  SCRIPT_KILL_PATTERN = /\b(kill|pkill|killall)\b|fuser\s+-k/

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
    pidfile = server_pidfile_path(tree)
    File.write(pidfile, "99999\n")

    env = demo_env(tree[:rails_log], "PORT" => port.to_s)

    _stdout, stderr, status = run_demo(tree[:demo_path], env)

    refute_predicate status, :success?, "expected failure when port #{port} is busy"
    assert_includes stderr, port.to_s, "stderr should name the port"
    assert_match(/\b#{holder_pid}\b/, stderr, "stderr should identify the holder PID")
    assert_match(/ruby/i, stderr, "stderr should name the holder command")
    assert_match(/PORT/i, stderr, "stderr should suggest choosing another PORT")

    assert_process_still_running(holder_pid)
    assert_port_held(port)
    assert_path_exists pidfile, "server.pid must remain when the port is busy"
    refute rails_invoked?(tree[:rails_log]),
           "fake rails must not run when the port is already in use"
  end

  test "fails when lsof reports no listeners but the port is occupied" do
    port = find_free_port
    holder_pid = spawn_port_holder(port)
    @port_holder_pids << holder_pid
    wait_for_port_listen(port, holder_pid)

    install_lsof_no_data_stub(@stub_bin)

    tree = build_demo_tree
    pidfile = server_pidfile_path(tree)
    File.write(pidfile, "424242\n")

    env = demo_env(tree[:rails_log], "PORT" => port.to_s)

    _stdout, stderr, status = run_demo(tree[:demo_path], env)

    refute_predicate status, :success?,
                     "expected failure when port #{port} is held but lsof is blind"
    assert_includes stderr, port.to_s, "stderr should name the port"
    assert_process_still_running(holder_pid)
    assert_port_held(port)
    assert_path_exists pidfile, "server.pid must remain when occupancy cannot be confirmed via lsof"
    assert_match(/could not be identified/i, stderr,
                 "stderr should explain the holder could not be identified via lsof")
    assert_match(/sudo lsof/, stderr,
                 "stderr should suggest sudo lsof to inspect the blind holder")
    refute rails_invoked?(tree[:rails_log]),
           "fake rails must not run when the port is already in use"
  end

  test "fails closed when the bind probe cannot run" do
    port = find_free_port
    install_ruby_probe_failure_stub(@stub_bin)

    tree = build_demo_tree
    pidfile = server_pidfile_path(tree)
    File.write(pidfile, "31337\n")

    env = demo_env(tree[:rails_log], "PORT" => port.to_s)

    _stdout, stderr, status = run_demo(tree[:demo_path], env)

    refute_predicate status, :success?,
                     "expected failure when the bind probe exits with an error"
    assert_match(/Could not check whether port/i, stderr)
    assert_path_exists pidfile, "server.pid must remain when the bind probe fails"
    refute rails_invoked?(tree[:rails_log]),
           "fake rails must not run when the bind probe fails"
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
    tree = build_demo_tree
    env = demo_env(tree[:rails_log])
    env.delete("PORT")

    _stdout, stderr, status = run_demo(tree[:demo_path], env)

    if port_free?(3000)
      assert_predicate status, :success?

      argv, recorded_port = read_rails_invocation(tree[:rails_log])
      assert_port_argv(argv, 3000)
      assert_equal "3000", recorded_port
    else
      refute_predicate status, :success?,
                       "expected failure when default port 3000 is busy"
      assert_includes stderr, "3000", "stderr should name the default port"
      refute rails_invoked?(tree[:rails_log]),
             "fake rails must not run when default port 3000 is busy"
    end
  end

  test "normalises PORT with a single leading zero" do
    port = find_free_port
    tree = build_demo_tree
    env = demo_env(tree[:rails_log], "PORT" => "0#{port}")

    _stdout, _stderr, status = run_demo(tree[:demo_path], env)

    assert_predicate status, :success?

    argv, recorded_port = read_rails_invocation(tree[:rails_log])
    assert_port_argv(argv, port)
    assert_equal port.to_s, recorded_port
  end

  test "rejects invalid PORT without starting rails" do
    %w[foo 0 65536 70000].each do |bad_port|
      tree = build_demo_tree
      env = demo_env(tree[:rails_log], "PORT" => bad_port)

      _stdout, stderr, status = run_demo(tree[:demo_path], env)

      refute_predicate status, :success?, "PORT=#{bad_port.inspect} should be rejected"
      assert_match(/PORT/i, stderr)
      refute rails_invoked?(tree[:rails_log]),
             "fake rails must not run for invalid PORT=#{bad_port.inspect}"
    end
  end

  test "rejects -p and --port CLI overrides without starting rails" do
    env_port = find_free_port
    bypass_port = find_free_port

    tree = build_demo_tree
    env = demo_env(tree[:rails_log], "PORT" => env_port.to_s)

    _stdout, stderr, status = run_demo(tree[:demo_path], env, "-p", bypass_port.to_s)

    refute_predicate status, :success?, "expected failure when -p overrides PORT"
    assert_match(/PORT/i, stderr)
    refute rails_invoked?(tree[:rails_log])

    tree2 = build_demo_tree
    env2 = demo_env(tree2[:rails_log], "PORT" => env_port.to_s)

    _stdout, stderr2, status2 = run_demo(tree2[:demo_path], env2, "--port=#{bypass_port}")

    refute_predicate status2, :success?, "expected failure when --port overrides PORT"
    assert_match(/PORT/i, stderr2)
    refute rails_invoked?(tree2[:rails_log])

    tree3 = build_demo_tree
    env3 = demo_env(tree3[:rails_log], "PORT" => env_port.to_s)

    _stdout, stderr3, status3 = run_demo(tree3[:demo_path], env3, "-p=#{bypass_port}")

    refute_predicate status3, :success?, "expected failure when -p=<port> overrides PORT"
    assert_match(/PORT/i, stderr3)
    refute rails_invoked?(tree3[:rails_log])
  end

  test "forwards other rails server args after -p from PORT" do
    port = find_free_port
    tree = build_demo_tree
    env = demo_env(tree[:rails_log], "PORT" => port.to_s)

    _stdout, _stderr, status = run_demo(tree[:demo_path], env, "-b", "0.0.0.0")

    assert_predicate status, :success?

    argv, recorded_port = read_rails_invocation(tree[:rails_log])
    assert_port_argv(argv, port)
    assert_equal port.to_s, recorded_port
    assert_includes argv, "-b"
    assert_includes argv, "0.0.0.0"
  end

  test "demo script source does not invoke kill on non-comment lines" do
    File.readlines(DEMO_SCRIPT_SOURCE).each_with_index do |line, index|
      next if line.strip.start_with?("#")

      assert_no_match(
        SCRIPT_KILL_PATTERN,
        line,
        "unexpected kill/pkill/killall/fuser -k on line #{index + 1}: #{line.strip}"
      )
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
    bind_address_free?("0.0.0.0", port) && bind_address_free?("::1", port)
  end

  def bind_address_free?(host, port)
    server = TCPServer.new(host, port)
    server.close
    true
  rescue Errno::EADDRINUSE, Errno::EACCES
    false
  rescue Errno::EADDRNOTAVAIL, Errno::EAFNOSUPPORT
    true
  end

  def port_in_use?(port)
    !bind_address_free?("127.0.0.1", port)
  end

  def spawn_port_holder(port)
    pid = Process.spawn(
      RbConfig.ruby,
      "-rsocket",
      "-e",
      'TCPServer.new("0.0.0.0", Integer(ARGV[0])); sleep',
      port.to_s,
      %i[out err] => "/dev/null"
    )
    pid
  end

  def wait_for_port_listen(port, holder_pid, timeout: 5)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    loop do
      raise "port holder #{holder_pid} exited early" unless process_still_running?(holder_pid)

      return if port_in_use?(port)

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

  def install_lsof_no_data_stub(stub_bin)
    path = File.join(stub_bin, "lsof")
    File.write(path, "#!/bin/sh\nexit 1\n")
    File.chmod(0o755, path)
  end

  def install_ruby_probe_failure_stub(stub_bin)
    path = File.join(stub_bin, "ruby")
    File.write(path, "#!/bin/sh\necho probe boom >&2\nexit 3\n")
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

  def server_pidfile_path(tree)
    File.join(tree[:root], "tmp", "pids", "server.pid")
  end

  def demo_env(rails_log, extra = {})
    path = "#{@stub_bin}:#{ENV.fetch('PATH', '')}"
    {
      "PATH" => path,
      "DEMO_TEST_RAILS_LOG" => rails_log
    }.merge(extra)
  end

  def run_demo(demo_path, env, *args)
    Open3.capture3(env, demo_path, *args)
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
    [ argv, recorded_port ]
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

  def assert_process_still_running(pid)
    assert process_still_running?(pid), "expected holder process #{pid} to still be running"
  end

  def process_still_running?(pid)
    Process.waitpid(pid, Process::WNOHANG).nil?
  rescue Errno::ECHILD
    false
  end

  def assert_port_held(port)
    TCPServer.new("127.0.0.1", port)
    flunk "expected port #{port} to remain in use"
  rescue Errno::EADDRINUSE
    nil
  end

  def terminate_pid(pid)
    return unless pid

    Process.kill("TERM", pid)
    Timeout.timeout(2) { Process.wait(pid) }
  rescue Errno::ESRCH, Errno::ECHILD, Timeout::Error
    Process.kill("KILL", pid) rescue nil
  end
end
