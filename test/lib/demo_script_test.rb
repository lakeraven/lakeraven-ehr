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

  test "suggests a free alternate PORT when PORT and PORT+1 are both busy" do
    skip "lsof not on PATH; required for port-holder detection" unless lsof_available?

    port = find_free_port
    while !port_free?(port + 1)
      port = find_free_port
    end

    holder_pid = spawn_port_holder(port)
    @port_holder_pids << holder_pid
    wait_for_port_listen(port, holder_pid)

    holder_pid_plus_one = spawn_port_holder(port + 1)
    @port_holder_pids << holder_pid_plus_one
    wait_for_port_listen(port + 1, holder_pid_plus_one)

    tree = build_demo_tree
    env = demo_env(tree[:rails_log], "PORT" => port.to_s)

    _stdout, stderr, status = run_demo(tree[:demo_path], env)

    refute_predicate status, :success?,
                     "expected failure when ports #{port} and #{port + 1} are busy"
    assert_suggested_alternate_port_not_busy(stderr, port)
    suggested = suggested_alternate_port(stderr)
    refute_equal port + 1, suggested,
                 "suggested PORT=#{suggested} must not be busy PORT+1 (#{port + 1})"
  end

  test "suggests an alternate PORT different from the busy port when lsof names the holder" do
    skip "lsof not on PATH; required for port-holder detection" unless lsof_available?

    port = default_busy_port_for_suggestion_contract
    holder_pid = ensure_port_holder(port)
    @port_holder_pids << holder_pid if holder_pid
    wait_for_port_listen(port, holder_pid) if holder_pid
    skip "port #{port} must be busy for alternate-port suggestion contract" unless port_in_use?(port)

    tree = build_demo_tree
    env = demo_env(tree[:rails_log], "PORT" => port.to_s)

    _stdout, stderr, status = run_demo(tree[:demo_path], env)

    refute_predicate status, :success?, "expected failure when port #{port} is busy"
    assert_suggested_alternate_port_not_busy(stderr, port)
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

  test "suggests an alternate PORT different from the busy port when lsof cannot see the holder" do
    port = default_busy_port_for_suggestion_contract
    holder_pid = ensure_port_holder(port)
    @port_holder_pids << holder_pid if holder_pid
    wait_for_port_listen(port, holder_pid) if holder_pid
    skip "port #{port} must be busy for alternate-port suggestion contract" unless port_in_use?(port)

    install_lsof_no_data_stub(@stub_bin)

    tree = build_demo_tree
    env = demo_env(tree[:rails_log], "PORT" => port.to_s)

    _stdout, stderr, status = run_demo(tree[:demo_path], env)

    refute_predicate status, :success?,
                     "expected failure when port #{port} is held but lsof is blind"
    assert_suggested_alternate_port_not_busy(stderr, port)
  end

  test "does not remove server.pid when PORT is free and pidfile references live server on another port" do
    skip "lsof not on PATH; required for port-holder detection" unless lsof_available?

    holder_port = find_free_port
    request_port = find_free_port
    refute_equal holder_port, request_port,
                 "holder and request ports must differ for this scenario"

    holder_pid = spawn_port_holder(holder_port)
    @port_holder_pids << holder_pid
    wait_for_port_listen(holder_port, holder_pid)

    tree = build_demo_tree
    pidfile = server_pidfile_path(tree)
    File.write(pidfile, "#{holder_pid}\n")

    env = demo_env(tree[:rails_log], "PORT" => request_port.to_s)

    _stdout, _stderr, status = run_demo(tree[:demo_path], env)

    assert_predicate status, :success?,
                     "expected success when PORT=#{request_port} is free"
    assert rails_invoked?(tree[:rails_log]),
           "fake rails should run when the requested port is free"
    assert_path_exists pidfile,
                       "server.pid must remain when another server holds a different port"
    assert_equal "#{holder_pid}\n", File.read(pidfile),
                 "server.pid must still reference the live holder PID"
    assert_process_still_running(holder_pid)
    assert_port_held(holder_port)
  end

  # On a usr-merged Linux runner, sh, env and lsof live in the same directory as
  # the system ruby (/usr/bin, and /bin is a symlink to it). Dropping every PATH
  # directory that holds a ruby therefore also dropped sh, so the demo's
  # `#!/usr/bin/env sh` line failed ("env: 'sh': No such file or directory")
  # before the script could say anything. The helper must remove ruby, not the
  # directories that happen to contain it.
  test "the ruby-less PATH keeps every other command reachable when it shares a directory with ruby" do
    shared = Dir.mktmpdir("demo_script_shared_bin_")
    @trees << shared
    File.write(File.join(shared, "ruby"), "#!/bin/sh\nexit 0\n")
    File.chmod(0o755, File.join(shared, "ruby"))
    File.symlink("/bin/sh", File.join(shared, "sh"))
    original = ENV["PATH"]
    ENV["PATH"] = shared
    begin
      resolved = path_without_ruby
    ensure
      ENV["PATH"] = original
    end

    found = ->(name) { resolved.split(":").any? { |dir| File.executable?(File.join(dir, name)) } }
    assert found.call("sh"), "sh must stay reachable: #{resolved}"
    refute found.call("ruby"), "ruby must not be reachable: #{resolved}"
  end

  test "busy port stderr explains when alternate-port search cannot run without ruby on PATH" do
    skip "lsof not on PATH; required for port-holder detection" unless lsof_available?

    port = find_free_port
    holder_pid = spawn_port_holder(port)
    @port_holder_pids << holder_pid
    wait_for_port_listen(port, holder_pid)

    tree = build_demo_tree
    env = demo_env(
      tree[:rails_log],
      "PORT" => port.to_s,
      "PATH" => path_without_ruby
    )

    _stdout, stderr, status = run_demo(tree[:demo_path], env)

    refute_predicate status, :success?,
                     "expected failure when port #{port} is busy and ruby is not on PATH"
    assert_includes stderr, port.to_s, "stderr should name the port"
    assert_match(/alternate.port search could not run/i, stderr,
                 "stderr should explain the alternate-port search could not run: #{stderr}")
    assert_match(/ruby/i, stderr, "stderr should mention ruby: #{stderr}")
    refute_match(/no free port found/i, stderr,
                 "must not claim no free port when ruby was unavailable for the search")
    assert_process_still_running(holder_pid)
    refute rails_invoked?(tree[:rails_log]),
           "fake rails must not run when the port is already in use"
  end

  test "busy port stderr explains when alternate-port search cannot run when ruby on PATH errors" do
    skip "lsof not on PATH; required for port-holder detection" unless lsof_available?

    port = find_free_port
    holder_pid = spawn_port_holder(port)
    @port_holder_pids << holder_pid
    wait_for_port_listen(port, holder_pid)

    install_ruby_shim_failure_stub(@stub_bin)

    tree = build_demo_tree
    env = demo_env(tree[:rails_log], "PORT" => port.to_s)

    _stdout, stderr, status = run_demo(tree[:demo_path], env)

    refute_predicate status, :success?,
                     "expected failure when port #{port} is busy and ruby probes error"
    assert_includes stderr, port.to_s, "stderr should name the port"
    assert_match(/search could not run/i, stderr,
                 "stderr should explain the alternate-port search could not run: #{stderr}")
    refute_match(/no free port found/i, stderr,
                 "must not claim no free port when ruby probes failed during the search")
    assert_process_still_running(holder_pid)
    refute rails_invoked?(tree[:rails_log]),
           "fake rails must not run when the port is already in use"
  end

  test "refuses rails server restart flags without starting rails or touching server.pid" do
    port = find_free_port
    pid_contents = "424242\n"

    %w[--restart --no-restart --skip-restart].each do |flag|
      tree = build_demo_tree
      pidfile = server_pidfile_path(tree)
      File.write(pidfile, pid_contents)
      env = demo_env(tree[:rails_log], "PORT" => port.to_s)

      _stdout, stderr, status = run_demo(tree[:demo_path], env, flag)

      refute_predicate status, :success?, "expected failure for #{flag}"
      assert_match(/restart/i, stderr, "stderr should mention restart for #{flag}")
      assert_equal pid_contents, File.read(pidfile),
                   "server.pid must remain unchanged when #{flag} is refused"
      refute rails_invoked?(tree[:rails_log]),
             "fake rails must not run when #{flag} is refused"
    end
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

  test "launch line chart URL reflects binding host" do
    port = find_free_port

    tree = build_demo_tree
    env = demo_env(tree[:rails_log], "PORT" => port.to_s)
    stdout, _stderr, status = run_demo(tree[:demo_path], env, "-b", "127.0.0.1")
    assert_predicate status, :success?, "expected success for -b 127.0.0.1"
    assert_includes stdout, "http://127.0.0.1:#{port}/patients/1",
                    "stdout should print chart URL for 127.0.0.1 bind"

    tree = build_demo_tree
    env = demo_env(tree[:rails_log], "PORT" => port.to_s)
    stdout, _stderr, status = run_demo(tree[:demo_path], env, "-b", "0.0.0.0")
    assert_predicate status, :success?, "expected success for -b 0.0.0.0"
    assert_includes stdout, "http://localhost:#{port}/",
                    "stdout should print localhost URL for 0.0.0.0 bind"

    tree = build_demo_tree
    env = demo_env(tree[:rails_log], "PORT" => port.to_s)
    stdout, _stderr, status = run_demo(tree[:demo_path], env, "-b", "::1")
    assert_predicate status, :success?, "expected success for -b ::1"
    assert_includes stdout, "http://[::1]:#{port}/",
                    "stdout should print bracketed IPv6 URL for ::1 bind"

    tree = build_demo_tree
    env = demo_env(tree[:rails_log], "PORT" => port.to_s, "BINDING" => "127.0.0.1")
    stdout, _stderr, status = run_demo(tree[:demo_path], env)
    assert_predicate status, :success?, "expected success for BINDING=127.0.0.1"
    assert_includes stdout, "http://127.0.0.1:#{port}/",
                    "stdout should print chart URL for BINDING=127.0.0.1"
  end

  test "defaults to port 3000 when PORT is unset" do
    tree = build_demo_tree
    env = demo_env(tree[:rails_log], "PORT" => nil)

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

  test "rejects -- anywhere in CLI arguments without starting rails" do
    env_port = find_free_port
    bypass_port = find_free_port
    ssl_binding = "ssl://127.0.0.1:#{bypass_port}?key=k&cert=c"

    double_dash_forms = [
      [ "-b", "--", "/tmp/demo.sock" ],
      [ "--binding", "--", ssl_binding ],
      [ "-db", "--", "unix:///tmp/x.sock" ],
      [ "-u", "--", "puma" ],
      [ "--" ]
    ]

    double_dash_forms.each do |form|
      tree = build_demo_tree
      env = demo_env(tree[:rails_log], "PORT" => env_port.to_s)

      _stdout, stderr, status = run_demo(tree[:demo_path], env, *form)
      form_desc = form.inspect

      refute_predicate status, :success?,
                       "expected failure when argv contains -- (#{form_desc})"
      assert_stderr_refuses_double_dash(stderr, form_desc)
      refute rails_invoked?(tree[:rails_log]),
             "fake rails must not run when argv contains -- (#{form_desc})"
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
      [ "--binding=ssl://127.0.0.1:#{n}" ],
      [ "-b", "127.0.0.1:#{n}" ],
      [ "--binding=127.0.0.1:#{n}" ]
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
      "127.0.0.1:#{n}",
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

  # Rails reads ENV.fetch("BINDING", "localhost"), so an exported empty
  # BINDING overrides the localhost default and Puma binds every interface
  # with the demo's auth bypass on. The script must drop it, not forward it.
  test "an empty BINDING never reaches rails" do
    port = find_free_port
    tree = build_demo_tree
    env = demo_env(tree[:rails_log], "PORT" => port.to_s, "BINDING" => "")

    stdout, _stderr, status = run_demo(tree[:demo_path], env)

    assert_predicate status, :success?, "expected success for BINDING=\"\""
    read_rails_invocation(tree[:rails_log])
    binding_log = File.join(File.dirname(tree[:rails_log]), "binding_env.log")
    assert_equal "unset", File.read(binding_log).strip,
                 "an empty BINDING must be unset before rails starts"
    assert_includes stdout, "http://localhost:#{port}/"
  end

  test "forwards allowlisted plain host bindings without embedded port to rails" do
    port = find_free_port

    [
      [ [ "-b", "127.0.0.1" ], "127.0.0.1" ],
      [ [ "-b=127.0.0.1" ], "127.0.0.1" ],
      [ [ "--binding", "0.0.0.0" ], "0.0.0.0" ],
      [ [ "--binding=::1" ], "::1" ]
    ].each do |form, host|
      tree = build_demo_tree
      env = demo_env(tree[:rails_log], "PORT" => port.to_s)

      _stdout, _stderr, status = run_demo(tree[:demo_path], env, *form)
      form_desc = form.inspect
      assert_predicate status, :success?, "expected success for #{form_desc}"

      argv, recorded_port = read_rails_invocation(tree[:rails_log])
      assert_port_argv(argv, port)
      assert_equal port.to_s, recorded_port
      assert_binding_host_in_argv!(argv, host, form_desc)
    end
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

  NEWLINE_PUMA_INHERIT_ENV_NAMES = [
    "A\nPUMA_INHERIT_0",
    "PUMA_INHERIT_0\n",
    "PUMA_INHERIT_0\nB",
    "XPUMA_INHERIT_3\nB"
  ].freeze

  test "refuses under bash when env name contains newline and PUMA_INHERIT_<digit>" do
    skip "bash not on PATH; required to reproduce bash env passthrough" unless shell_available?("bash")

    NEWLINE_PUMA_INHERIT_ENV_NAMES.each do |bad_name|
      port = find_free_port
      tree = build_demo_tree
      env = demo_env(
        tree[:rails_log],
        "PORT" => port.to_s,
        bad_name => "9:tcp://localhost:#{port}"
      )

      _stdout, stderr, status = run_demo_with_shell("bash", tree[:demo_path], env)

      refute_predicate status, :success?,
                       "demo must refuse when env name #{bad_name.inspect} escapes env-text scans"
      assert_match(/PUMA_INHERIT/i, stderr)
      refute rails_invoked?(tree[:rails_log]),
             "fake rails must not run when #{bad_name.inspect} remains in the environment"
    end
  end

  test "under bash refuses or strips PUMA_INHERIT when env is hidden by BASH_FUNC_env%%" do
    skip "bash not on PATH; required to reproduce bash env passthrough" unless shell_available?("bash")

    port = find_free_port
    tree = build_demo_tree
    env = demo_env(
      tree[:rails_log],
      "PORT" => port.to_s,
      "PUMA_INHERIT_0" => "9:tcp://localhost:#{port}",
      "BASH_FUNC_env%%" => '() { command env "$@" | command grep -v PUMA_INHERIT; }'
    )

    _stdout, stderr, status = run_demo_with_shell("bash", tree[:demo_path], env)

    if status.success?
      argv, recorded_port = read_rails_invocation(tree[:rails_log])
      assert_port_argv(argv, port)
      assert_equal port.to_s, recorded_port
      assert_no_puma_inherit_digit_env_names!(tree[:rails_log])
    else
      assert_match(/PUMA_INHERIT/i, stderr)
      refute rails_invoked?(tree[:rails_log]),
             "fake rails must not run when PUMA_INHERIT_<digit> cannot be cleared"
    end
  end

  test "under bash refuses when BASH_FUNC_ruby%% stubs the final PUMA_INHERIT ruby check" do
    skip "bash not on PATH; required to reproduce bash function shadowing" unless shell_available?("bash")

    port = find_free_port
    tree = build_demo_tree
    bad_name = "A\nPUMA_INHERIT_0"
    env = demo_env(
      tree[:rails_log],
      "PORT" => port.to_s,
      bad_name => "9:x:",
      "BASH_FUNC_ruby%%" => "() { return 0; }"
    )

    _stdout, stderr, status = run_demo_with_shell("bash", tree[:demo_path], env)

    refute_predicate status, :success?,
                     "demo must refuse when ruby no longer enforces PUMA_INHERIT_<digit> keys"
    assert_match(/PUMA_INHERIT/i, stderr)
    refute rails_invoked?(tree[:rails_log]),
           "fake rails must not run when the PUMA_INHERIT guard is bypassed via BASH_FUNC_ruby%%"
  end

  test "under bash refuses or strips PUMA_INHERIT when command env is hidden by BASH_FUNC_command%%" do
    skip "bash not on PATH; required to reproduce bash function shadowing" unless shell_available?("bash")

    port = find_free_port
    tree = build_demo_tree
    env = demo_env(
      tree[:rails_log],
      "PORT" => port.to_s,
      "PUMA_INHERIT_0" => "9:x",
      "BASH_FUNC_ruby%%" => "() { return 0; }",
      "BASH_FUNC_command%%" => "() { return 0; }"
    )

    _stdout, stderr, status = run_demo_with_shell("bash", tree[:demo_path], env)

    if status.success?
      argv, recorded_port = read_rails_invocation(tree[:rails_log])
      assert_port_argv(argv, port)
      assert_equal port.to_s, recorded_port
      assert_no_puma_inherit_digit_env_names!(tree[:rails_log])
    else
      refute rails_invoked?(tree[:rails_log]),
             "fake rails must not run when PUMA_INHERIT_<digit> cannot be cleared"
      assert_match(/PUMA_INHERIT/i, stderr)
    end
  end

  test "under bash still refuses busy port when BASH_FUNC_lsof%% stubs lsof" do
    skip "bash not on PATH; required to reproduce bash function shadowing" unless shell_available?("bash")

    port = find_free_port
    holder_pid = spawn_port_holder(port)
    @port_holder_pids << holder_pid
    wait_for_port_listen(port, holder_pid)

    tree = build_demo_tree
    env = demo_env(
      tree[:rails_log],
      "PORT" => port.to_s,
      "BASH_FUNC_lsof%%" => "() { return 0; }"
    )

    _stdout, stderr, status = run_demo_with_shell("bash", tree[:demo_path], env)

    refute_predicate status, :success?,
                     "expected failure when port #{port} is busy even if lsof is stubbed"
    assert_includes stderr, port.to_s, "stderr should name the port"
    refute rails_invoked?(tree[:rails_log]),
           "fake rails must not run when the port is already in use"
    assert_process_still_running(holder_pid)
    assert_port_held(port)
  end

  CGI_HANDLER_ENV_VARS = %w[RACKUP_HANDLER RACK_HANDLER].freeze

  CGI_HANDLER_CLI_FORMS = [
    [ "-u", "cgi" ],
    [ "--using", "cgi" ],
    [ "--using=cgi" ],
    [ "-ucgi" ]
  ].freeze

  PUMA_HANDLER_CLI_FORMS = [
    [ "-u", "puma" ],
    [ "--using=puma" ]
  ].freeze

  test "under bash drops or refuses RACKUP_HANDLER and RACK_HANDLER cgi" do
    skip "bash not on PATH; required for handler env contract" unless shell_available?("bash")

    CGI_HANDLER_ENV_VARS.each do |var|
      port = find_free_port
      tree = build_demo_tree
      env = demo_env(tree[:rails_log], "PORT" => port.to_s, var => "cgi")

      _stdout, _stderr, status = run_demo_with_shell("bash", tree[:demo_path], env)

      if status.success?
        argv, recorded_port = read_rails_invocation(tree[:rails_log])
        assert_port_argv(argv, port)
        assert_equal port.to_s, recorded_port
        rack_env = read_rack_handler_env(tree[:rails_log])
        assert_equal "", rack_env.fetch(var),
                     "#{var}=cgi must not reach rails (handler would not listen on PORT)"
      else
        refute rails_invoked?(tree[:rails_log]),
               "fake rails must not run when #{var}=cgi is refused"
      end
    end
  end

  test "under bash refuses cgi handler CLI overrides without starting rails" do
    skip "bash not on PATH; required for handler CLI contract" unless shell_available?("bash")

    port = find_free_port

    CGI_HANDLER_CLI_FORMS.each do |form|
      tree = build_demo_tree
      env = demo_env(tree[:rails_log], "PORT" => port.to_s)

      _stdout, stderr, status = run_demo_with_shell("bash", tree[:demo_path], env, *form)
      form_desc = form.inspect

      refute_predicate status, :success?,
                       "expected failure for handler override #{form_desc}"
      assert_match(/handler|puma|cgi/i, stderr,
                   "stderr should mention handler, puma, or cgi for #{form_desc}")
      refute rails_invoked?(tree[:rails_log]),
             "fake rails must not run for handler override #{form_desc}"
    end
  end

  test "under bash refuses puma handler CLI overrides without starting rails" do
    skip "bash not on PATH; required for handler CLI contract" unless shell_available?("bash")

    port = find_free_port

    PUMA_HANDLER_CLI_FORMS.each do |form|
      tree = build_demo_tree
      env = demo_env(tree[:rails_log], "PORT" => port.to_s)

      _stdout, stderr, status = run_demo_with_shell("bash", tree[:demo_path], env, *form)
      form_desc = form.inspect

      refute_predicate status, :success?,
                       "expected failure for handler override #{form_desc}"
      assert_stderr_lists_accepted_binding_forms(stderr, form_desc)
      refute rails_invoked?(tree[:rails_log]),
             "fake rails must not run for handler override #{form_desc}"
    end
  end

  test "under bash forwards X_PUMA_INHERIT_FOO and strips valid-identifier PUMA_INHERIT_<digit> names" do
    skip "bash not on PATH; required to verify bash pre-exec PUMA_INHERIT guard" unless shell_available?("bash")

    port = find_free_port
    inherit_0 = "9:tcp://localhost:#{port}"
    tree = build_demo_tree
    env = demo_env(
      tree[:rails_log],
      "PORT" => port.to_s,
      "PUMA_INHERIT_0" => inherit_0,
      "PUMA_INHERIT_1" => "10:tcp://127.0.0.1:42424",
      "X_PUMA_INHERIT_FOO" => "keep"
    )

    _stdout, _stderr, status = run_demo_with_shell("bash", tree[:demo_path], env)

    assert_predicate status, :success?,
                     "expected success when valid-identifier PUMA_INHERIT names are stripped under bash"

    argv, recorded_port = read_rails_invocation(tree[:rails_log])
    assert_port_argv(argv, port)
    assert_equal port.to_s, recorded_port
    assert_no_puma_inherit_digit_env_names!(tree[:rails_log])

    inherit_env = read_puma_inherit_env(tree[:rails_log])
    assert_equal "keep", inherit_env.fetch("X_PUMA_INHERIT_FOO"),
                 "X_PUMA_INHERIT_FOO must reach rails when it has no PUMA_INHERIT_<digit> segment"
    assert_equal "", inherit_env.fetch("PUMA_INHERIT_0"),
                 "PUMA_INHERIT_0 must be unset when rails runs"
    assert_equal "", inherit_env.fetch("PUMA_INHERIT_1"),
                 "PUMA_INHERIT_1 must be unset when rails runs"
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

  test "rejects non-allowlisted CLI arguments without starting rails or running bind probe" do
    env_port = find_free_port
    pid_path = File.join(Dir.mktmpdir("demo_script_pid_refusal_"), "x.pid")

    refused_forms = [
      [ "-e", "production" ],
      [ "-e", "development" ],
      [ "-P", pid_path ],
      [ "--pid=#{pid_path}" ],
      [ "-d" ],
      [ "-C" ],
      [ "-u", "puma" ],
      [ "-b192.0.2.10" ],
      [ "-b0.0.0.0" ],
      [ "-b" ],
      [ "-b", "-d" ],
      [ "-b", "127.0.0.1", "-b", "127.0.0.2" ],
      [ "foo" ]
    ]

    refused_forms.each do |form|
      tree = build_demo_tree
      env = demo_env(tree[:rails_log], "PORT" => env_port.to_s)

      _stdout, stderr, status = run_demo(tree[:demo_path], env, *form)
      form_desc = form.inspect

      refute_predicate status, :success?,
                       "expected failure for non-allowlisted argv #{form_desc}"
      assert_stderr_lists_accepted_binding_forms(stderr, form_desc)
      refute rails_invoked?(tree[:rails_log]),
             "fake rails must not run for non-allowlisted argv #{form_desc}"
    end
  ensure
    FileUtils.remove_entry(File.dirname(pid_path)) if pid_path && Dir.exist?(File.dirname(pid_path))
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

  # Every address the script probes. On macOS, SO_REUSEADDR lets a loopback
  # bind succeed beside a 0.0.0.0 holder, so loopback alone reads as free.
  def port_in_use?(port)
    !port_free?(port)
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

  def install_ruby_shim_failure_stub(stub_bin)
    path = File.join(stub_bin, "ruby")
    File.write(path, "#!/bin/sh\necho 'rbenv: version not installed' >&2\nexit 1\n")
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

        inherit_keys = %w[
          PUMA_INHERIT_0 PUMA_INHERIT_1 X_PUMA_INHERIT_FOO
          RACKUP_HANDLER RACK_HANDLER
        ]
        inherit_lines = inherit_keys.map { |key| "#{key}=#{ENV.fetch(key, '')}" }
        File.write(inherit_log, inherit_lines.join("\n") + "\n")

        binding_state = ENV.key?("BINDING") ? "set:#{ENV['BINDING']}" : "unset"
        File.write(File.join(File.dirname(log), "binding_env.log"), binding_state + "\n")

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
      "DEMO_TEST_PUMA_INHERIT_MATCH_LOG" => puma_inherit_match_log,
      "PORT" => nil,
      "BINDING" => nil,
      "RACK_HANDLER" => nil,
      "RACKUP_HANDLER" => nil
    }.merge(extra)
  end

  # A PATH with every command the real one has except `ruby`. Dropping whole
  # directories is not enough: on a usr-merged Linux runner sh, env and lsof sit
  # beside the system ruby, so the demo's `#!/usr/bin/env sh` would not even
  # start. Each other command is linked into a private directory instead.
  def path_without_ruby
    bin = Dir.mktmpdir("demo_script_no_ruby_bin_")
    @trees << bin
    ENV.fetch("PATH", "").split(":").each do |dir|
      next if dir.empty? || !File.directory?(dir)

      Dir.children(dir).each do |name|
        source = File.join(dir, name)
        link = File.join(bin, name)
        next if name == "ruby" || File.symlink?(link) || !File.file?(source) || !File.executable?(source)

        File.symlink(source, link)
      end
    end
    "#{@stub_bin}:#{bin}"
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

  def read_rack_handler_env(rails_log)
    env = read_puma_inherit_env(rails_log)
    CGI_HANDLER_ENV_VARS.each do |key|
      env[key] = "" unless env.key?(key)
    end
    env
  end

  def assert_handler_argv_includes_puma!(argv, form)
    if form == [ "-u", "puma" ]
      idx = argv.index("-u")
      assert idx, "expected -u in argv: #{argv.inspect}"
      assert_equal "puma", argv[idx + 1]
    elsif form == [ "--using=puma" ]
      assert argv.include?("--using=puma") ||
               (argv.index("--using") && argv[argv.index("--using") + 1] == "puma"),
             "expected puma handler in argv: #{argv.inspect}"
    else
      flunk "unexpected handler form: #{form.inspect}"
    end
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
    refute port_free?(port), "expected port #{port} to remain in use"
  end

  def default_busy_port_for_suggestion_contract
    find_free_port
  end

  def ensure_port_holder(port)
    return spawn_port_holder(port) unless port_in_use?(port)

    nil
  end

  def suggested_alternate_port(stderr)
    match = stderr.match(/choose another port.*PORT=(\d+)/i)
    match ? match[1].to_i : nil
  end

  def assert_stderr_refuses_double_dash(stderr, form_desc = nil)
    context = form_desc ? " for #{form_desc}" : ""
    assert_match(/--/, stderr, "stderr should mention --#{context}")
    assert_match(/Thor|separator|next argument/i, stderr,
                 "stderr should name why -- is refused#{context}: #{stderr}")
  end

  def assert_stderr_lists_accepted_binding_forms(stderr, form_desc = nil)
    context = form_desc ? " for #{form_desc}" : ""
    assert_match(/-b\b/, stderr, "stderr should list -b HOST#{context}: #{stderr}")
    assert_match(/-b=/, stderr, "stderr should list -b=HOST#{context}: #{stderr}")
    assert_match(/--binding\b/, stderr, "stderr should list --binding HOST#{context}: #{stderr}")
    assert_match(/--binding=/, stderr, "stderr should list --binding=HOST#{context}: #{stderr}")
  end

  def assert_binding_host_in_argv!(argv, host, form_desc = nil)
    context = form_desc ? " (#{form_desc})" : ""
    ok = (argv.index("-b") && argv[argv.index("-b") + 1] == host) ||
         argv.include?("-b=#{host}") ||
         (argv.index("--binding") && argv[argv.index("--binding") + 1] == host) ||
         argv.include?("--binding=#{host}")
    assert ok, "expected #{host} binding in argv#{context}: #{argv.inspect}"
  end

  def assert_suggested_alternate_port_not_busy(stderr, busy_port)
    suggested = suggested_alternate_port(stderr)
    assert suggested, "stderr should suggest an alternate PORT= number: #{stderr}"
    refute_equal busy_port, suggested,
                 "suggested PORT=#{suggested} must differ from busy port #{busy_port}"
    refute port_in_use?(suggested),
           "suggested PORT=#{suggested} must not be in use at assertion time"
  end

  def terminate_pid(pid)
    return unless pid

    Process.kill("TERM", pid)
    Timeout.timeout(2) { Process.wait(pid) }
  rescue Errno::ESRCH, Errno::ECHILD, Timeout::Error
    Process.kill("KILL", pid) rescue nil
  end
end
