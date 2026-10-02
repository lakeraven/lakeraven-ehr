# frozen_string_literal: true

# The dummy app mounts the engine under a prefix (test/dummy/config/routes.rb).
# Steps that request engine routes go through here, so a remount is one edit
# (lakeraven-ehr#492).
ENGINE_MOUNT = "/lakeraven-ehr"

module EngineMountHelpers
  def engine_path(path)
    "#{ENGINE_MOUNT}#{path}"
  end
end
World(EngineMountHelpers)
