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

    stdout, stderr, status = run_demo(tree[:demo_path], env)

    if port_free?(3000)
      assert_predicate status, :success?
      assert_includes stdout, "http://localhost:3000/",
                      "stdout URL should use default port 3000"

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
    n = bypass_port.to_s

    override_forms = [
      [ "-p", n ],
      [ "-p#{n}" ],
      [ "-p=#{n}" ],
      [ "--port", n ],
      [ "--port=#{n}" ],
      [ "-dp", n ],
      [ "-Cp", n ],
      [ "-pd", n ],
      [ "--no-port", n ],
      [ "--skip-port", n ],
      [ "--no-port=#{n}" ],
      [ "--skip-port=#{n}" ],
      [ "--no-po", n ],
      [ "--skip-po", n ],
      [ "--no-por=#{n}" ],
      [ "--no_port", n ],
      [ "--skip_port", n ],
      [ "--no_port=#{n}" ],
      [ "--skip_port=#{n}" ],
      [ "--no_po", n ]
    ]

    override_forms.each do |form|
      tree = build_demo_tree
      env = demo_env(tree[:rails_log], "PORT" => env_port.to_s)

      _stdout, stderr, status = run_demo(tree[:demo_path], env, *form)
      form_desc = form.inspect

      refute_predicate status, :success?,
                       "expected failure for CLI override #{form_desc}"
      assert_match(/PORT/i, stderr, "stderr should mention PORT for #{form_desc}")
      refute rails_invoked?(tree[:rails_log]),
             "fake rails must not run for CLI override #{form_desc}"
    end
  end

  test "rejects binding URIs with embedded ports without starting rails" do
    env_port = find_free_port
    bypass_port = find_free_port
    n = bypass_port.to_s

    binding_forms = [
      [ "-b", "ssl://127.0.0.1:#{n}?key=k&cert=c" ],
      [ "-bssl://127.0.0.1:#{n}" ],
      [ "-b=tcp://127.0.0.1:#{n}" ],
      [ "--binding", "tcp://127.0.0.1:#{n}" ],
      [ "--binding=ssl://127.0.0.1:#{n}" ]
    ]

    binding_forms.each do |form|
      tree = build_demo_tree
      env = demo_env(tree[:rails_log], "PORT" => env_port.to_s)

      _stdout, stderr, status = run_demo(tree[:demo_path], env, *form)
      form_desc = form.inspect

      refute_predicate status, :success?,
                       "expected failure for binding override #{form_desc}"
      assert_match(/PORT|binding/i, stderr,
                   "stderr should mention PORT or binding for #{form_desc}")
      refute rails_invoked?(tree[:rails_log]),
             "fake rails must not run for binding override #{form_desc}"
    end
  end

  test "rejects BINDING URIs with embedded ports without starting rails" do
    env_port = find_free_port
    bypass_port = find_free_port
    n = bypass_port.to_s

    binding_values = [
      "ssl://127.0.0.1:#{n}?key=k&cert=c",
      "tcp://127.0.0.1:#{n}",
      "unix:///tmp/demo.sock"
    ]

    binding_values.each do |binding_value|
      tree = build_demo_tree
      env = demo_env(tree[:rails_log], "PORT" => env_port.to_s, "BINDING" => binding_value)

      _stdout, stderr, status = run_demo(tree[:demo_path], env)
      desc = "BINDING=#{binding_value.inspect} without -b"

      refute_predicate status, :success?, "expected failure for #{desc}"
      assert_match(/BINDING/i, stderr, "stderr should mention BINDING for #{desc}")
      refute rails_invoked?(tree[:rails_log]),
             "fake rails must not run for #{desc}"

      tree = build_demo_tree
      env = demo_env(tree[:rails_log], "PORT" => env_port.to_s, "BINDING" => binding_value)

      _stdout, stderr, status = run_demo(tree[:demo_path], env, "-b", "127.0.0.1")
      desc = "BINDING=#{binding_value.inspect} with -b 127.0.0.1"

      refute_predicate status, :success?, "expected failure for #{desc}"
      assert_match(/BINDING/i, stderr, "stderr should mention BINDING for #{desc}")
      refute rails_invoked?(tree[:rails_log]),
             "fake rails must not run for #{desc}"
    end
  end

  test "forwards plain host BINDING to rails on PORT" do
    port = find_free_port
    tree = build_demo_tree
    env = demo_env(tree[:rails_log], "PORT" => port.to_s, "BINDING" => "127.0.0.1")

    _stdout, _stderr, status = run_demo(tree[:demo_path], env)

    assert_predicate status, :success?, "expected success for BINDING=127.0.0.1"

    argv, recorded_port = read_rails_invocation(tree[:rails_log])
    assert_port_argv(argv, port)
    assert_equal port.to_s, recorded_port
  end

  test "forwards plain host bindings without embedded port to rails" do
    port = find_free_port
    tree = build_demo_tree
    env = demo_env(tree[:rails_log], "PORT" => port.to_s)

    _stdout, _stderr, status = run_demo(tree[:demo_path], env, "-b", "127.0.0.1")
    assert_predicate status, :success?, "expected success for -b 127.0.0.1"

    argv, recorded_port = read_rails_invocation(tree[:rails_log])
    assert_port_argv(argv, port)
    assert_equal port.to_s, recorded_port
    assert_includes argv, "-b"
    assert_includes argv, "127.0.0.1"

    tree = build_demo_tree
    env = demo_env(tree[:rails_log], "PORT" => port.to_s)

    _stdout, _stderr, status = run_demo(tree[:demo_path], env, "--binding=0.0.0.0")
    assert_predicate status, :success?, "expected success for --binding=0.0.0.0"

    argv, recorded_port = read_rails_invocation(tree[:rails_log])
    assert_port_argv(argv, port)
    assert_equal port.to_s, recorded_port
    assert(
      (argv.index("-b") && argv[argv.index("-b") + 1] == "0.0.0.0") ||
        argv.include?("--binding=0.0.0.0") ||
        (argv.index("--binding") && argv[argv.index("--binding") + 1] == "0.0.0.0"),
      "expected 0.0.0.0 binding in argv: #{argv.inspect}"
    )

    tree = build_demo_tree
    env = demo_env(tree[:rails_log], "PORT" => port.to_s, "BINDING" => "localhost")

    _stdout, _stderr, status = run_demo(tree[:demo_path], env)
    assert_predicate status, :success?, "expected success for BINDING=localhost"

    argv, recorded_port = read_rails_invocation(tree[:rails_log])
    assert_port_argv(argv, port)
    assert_equal port.to_s, recorded_port

    tree = build_demo_tree
    env = demo_env(tree[:rails_log], "PORT" => port.to_s)

    _stdout, _stderr, status = run_demo(tree[:demo_path], env, "-b", "::1")
    assert_predicate status, :success?, "expected success for -b ::1"

    argv, recorded_port = read_rails_invocation(tree[:rails_log])
    assert_port_argv(argv, port)
    assert_equal port.to_s, recorded_port
    assert_includes argv, "-b"
    assert_includes argv, "::1"
  end

  test "rejects unix socket style BINDING without starting rails" do
    env_port = find_free_port

    %w[/tmp/demo.sock ./demo.sock @demo].each do |binding_value|
      tree = build_demo_tree
      env = demo_env(tree[:rails_log], "PORT" => env_port.to_s, "BINDING" => binding_value)

      _stdout, stderr, status = run_demo(tree[:demo_path], env)
      desc = "BINDING=#{binding_value.inspect}"

      refute_predicate status, :success?, "expected failure for #{desc}"
      assert_match(/BINDING|binding|PORT/i, stderr, "stderr should mention BINDING, binding, or PORT for #{desc}")
      refute rails_invoked?(tree[:rails_log]),
             "fake rails must not run for #{desc}"
    end
  end

  test "rejects unix socket style CLI bindings without starting rails" do
    env_port = find_free_port

    socket_hosts = %w[/tmp/demo.sock ./demo.sock @demo]
    binding_forms = socket_hosts.flat_map do |host|
      [
        [ "-b", host ],
        [ "-b#{host}" ],
        [ "-b=#{host}" ],
        [ "--binding", host ],
        [ "--binding=#{host}" ]
      ]
    end

    binding_forms.each do |form|
      tree = build_demo_tree
      env = demo_env(tree[:rails_log], "PORT" => env_port.to_s)

      _stdout, stderr, status = run_demo(tree[:demo_path], env, *form)
      form_desc = form.inspect

      refute_predicate status, :success?,
                       "expected failure for socket-style binding #{form_desc}"
      assert_match(/BINDING|binding|PORT/i, stderr,
                   "stderr should mention BINDING, binding, or PORT for #{form_desc}")
      refute rails_invoked?(tree[:rails_log]),
             "fake rails must not run for socket-style binding #{form_desc}"
    end
  end

  test "does not forward PUMA_INHERIT variables to rails" do
    port = find_free_port
    tree = build_demo_tree
    inherit_0 = "9:tcp://localhost:#{port}"
    inherit_1 = "10:tcp://127.0.0.1:42424"
    env = demo_env(
      tree[:rails_log],
      "PORT" => port.to_s,
      "PUMA_INHERIT_0" => inherit_0,
      "PUMA_INHERIT_1" => inherit_1
    )

    _stdout, _stderr, status = run_demo(tree[:demo_path], env)

    assert_predicate status, :success?

    argv, recorded_port = read_rails_invocation(tree[:rails_log])
    assert_port_argv(argv, port)
    assert_equal port.to_s, recorded_port

    inherit_env = read_puma_inherit_env(tree[:rails_log])
    assert_equal "", inherit_env.fetch("PUMA_INHERIT_0"),
                 "PUMA_INHERIT_0 must be unset when rails runs"
    assert_equal "", inherit_env.fetch("PUMA_INHERIT_1"),
                 "PUMA_INHERIT_1 must be unset when rails runs"
    assert_no_puma_inherit_digit_env_names!(tree[:rails_log])
  end

  test "does not forward env names containing PUMA_INHERIT_<digit> anywhere to rails" do
    port = find_free_port
    inherit_0 = "9:tcp://localhost:#{port}"
    extra = {
      "PORT" => port.to_s,
      "X_PUMA_INHERIT_0" => inherit_0,
      "MY_PUMA_INHERIT_12" => "x",
      "puma_PUMA_INHERIT_1" => "y"
    }

    tree = build_demo_tree
    env = demo_env(tree[:rails_log], extra)
    _stdout, _stderr, status = run_demo(tree[:demo_path], env)

    assert_predicate status, :success?

    argv, recorded_port = read_rails_invocation(tree[:rails_log])
    assert_port_argv(argv, port)
    assert_equal port.to_s, recorded_port
    assert_no_puma_inherit_digit_env_names!(tree[:rails_log])

    skip "bash not on PATH; required to verify identifier PUMA_INHERIT names under bash" unless shell_available?("bash")

    tree = build_demo_tree
    env = demo_env(tree[:rails_log], extra)
    _stdout, _stderr, status = run_demo_with_shell("bash", tree[:demo_path], env)

    assert_predicate status, :success?, "expected success when valid-identifier PUMA_INHERIT names are stripped under bash"

    argv, recorded_port = read_rails_invocation(tree[:rails_log])
    assert_port_argv(argv, port)
    assert_equal port.to_s, recorded_port
    assert_no_puma_inherit_digit_env_names!(tree[:rails_log])
  end

  test "refuses to start under bash when env has non-identifier PUMA_INHERIT_<digit> name" do
    skip "bash not on PATH; required to reproduce bash env passthrough" unless shell_available?("bash")

    port = find_free_port
    tree = build_demo_tree
    bad_name = "1X_PUMA_INHERIT_0"
    env = demo_env(
      tree[:rails_log],
      "PORT" => port.to_s,
      bad_name => "9:tcp://localhost:#{port}"
    )

    _stdout, stderr, status = run_demo_with_shell("bash", tree[:demo_path], env)

    refute_predicate status, :success?,
                     "demo must refuse when #{bad_name} cannot be removed from the environment"
    assert_match(/PUMA_INHERIT/i, stderr)
    refute rails_invoked?(tree[:rails_log]),
           "fake rails must not run when a non-identifier PUMA_INHERIT_<digit> name remains"
  end

  test "under dash non-identifier PUMA_INHERIT_<digit> env is dropped or demo refuses" do
    skip "dash not on PATH" unless shell_available?("dash")

    port = find_free_port
    tree = build_demo_tree
    bad_name = "1X_PUMA_INHERIT_0"
    env = demo_env(
      tree[:rails_log],
      "PORT" => port.to_s,
      bad_name => "9:tcp://localhost:#{port}"
    )

    _stdout, _stderr, status = run_demo_with_shell("dash", tree[:demo_path], env)

    if status.success?
      argv, recorded_port = read_rails_invocation(tree[:rails_log])
      assert_port_argv(argv, port)
      assert_equal port.to_s, recorded_port
      assert_no_puma_inherit_digit_env_names!(tree[:rails_log])
    else
      refute rails_invoked?(tree[:rails_log]),
             "fake rails must not run when demo refuses a non-identifier PUMA_INHERIT name"
    end
  end

  test "forwards PUMA_INHERIT-like names without a trailing digit to rails" do
    port = find_free_port
    tree = build_demo_tree
    env = demo_env(
      tree[:rails_log],
      "PORT" => port.to_s,
      "X_PUMA_INHERIT_FOO" => "keep"
    )

    _stdout, _stderr, status = run_demo(tree[:demo_path], env)

    assert_predicate status, :success?

    argv, recorded_port = read_rails_invocation(tree[:rails_log])
    assert_port_argv(argv, port)
    assert_equal port.to_s, recorded_port
    assert_no_puma_inherit_digit_env_names!(tree[:rails_log])

    inherit_env = read_puma_inherit_env(tree[:rails_log])
    assert_equal "keep", inherit_env.fetch("X_PUMA_INHERIT_FOO"),
                 "X_PUMA_INHERIT_FOO must reach rails when it has no PUMA_INHERIT_<digit> segment"
  end

  test "forwards other rails server args after -p from PORT" do
    port = find_free_port
    tree = build_demo_tree
    env = demo_env(tree[:rails_log], "PORT" => port.to_s)

    _stdout, _stderr, status = run_demo(
      tree[:demo_path], env,
      "-b", "0.0.0.0",
      "-P", "tmp/pids/other.pid"
    )

    assert_predicate status, :success?

    argv, recorded_port = read_rails_invocation(tree[:rails_log])
    assert_port_argv(argv, port)
    assert_equal port.to_s, recorded_port
    assert_includes argv, "-b"
    assert_includes argv, "0.0.0.0"
    assert_includes argv, "-P"
    assert_includes argv, "tmp/pids/other.pid"
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
    bind_address_free?("0.0.0.0", port) &&
      bind_address_free?("127.0.0.1", port) &&
      bind_address_free?("::1", port)
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
      <<~'STUB'
        #!/usr/bin/env ruby
        log = ENV.fetch("DEMO_TEST_RAILS_LOG")
        inherit_log = ENV.fetch("DEMO_TEST_PUMA_INHERIT_LOG")
        match_log = ENV.fetch("DEMO_TEST_PUMA_INHERIT_MATCH_LOG")

        File.write(log, ["PORT=#{ENV['PORT']}", *ARGV].join("\n") + "\n")

        inherit_keys = %w[PUMA_INHERIT_0 PUMA_INHERIT_1 X_PUMA_INHERIT_FOO]
        inherit_lines = inherit_keys.map { |key| "#{key}=#{ENV.fetch(key, '')}" }
        File.write(inherit_log, inherit_lines.join("\n") + "\n")

        digit_keys = ENV.keys.grep(/PUMA_INHERIT_\d/)
        File.write(match_log, digit_keys.join("\n") + (digit_keys.empty? ? "" : "\n"))

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
    log_dir = File.dirname(rails_log)
    puma_inherit_log = File.join(log_dir, "puma_inherit_env.log")
    puma_inherit_match_log = File.join(log_dir, "puma_inherit_digit_env.log")
    {
      "PATH" => path,
      "DEMO_TEST_RAILS_LOG" => rails_log,
      "DEMO_TEST_PUMA_INHERIT_LOG" => puma_inherit_log,
      "DEMO_TEST_PUMA_INHERIT_MATCH_LOG" => puma_inherit_match_log
    }.merge(extra)
  end

  def shell_available?(shell)
    system("command -v #{shell} >/dev/null 2>&1")
  end

  def run_demo(demo_path, env, *args)
    Open3.capture3(env, demo_path, *args)
  end

  def run_demo_with_shell(shell, demo_path, env, *args)
    Open3.capture3(env, shell, demo_path, *args)
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

  def read_puma_inherit_env(rails_log)
    path = File.join(File.dirname(rails_log), "puma_inherit_env.log")
    assert File.exist?(path), "expected puma inherit env log at #{path}"

    values = {}
    File.readlines(path, chomp: true).each do |line|
      key, val = line.split("=", 2)
      values[key] = val || ""
    end
    values
  end

  def read_puma_inherit_digit_env_lines(rails_log)
    path = File.join(File.dirname(rails_log), "puma_inherit_digit_env.log")
    assert File.exist?(path), "expected PUMA_INHERIT_<digit> env key log at #{path}"

    File.readlines(path, chomp: true).reject(&:empty?)
  end

  def assert_no_puma_inherit_digit_env_names!(rails_log)
    lines = read_puma_inherit_digit_env_lines(rails_log)
    assert_empty lines,
                 "no env key matching /PUMA_INHERIT_\\d/ may reach rails; got: #{lines.inspect}"
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
