require_relative 'domain'

require 'sourced/ui/dashboard'
require 'datastar/async_executor'

Datastar.config.executor = Datastar::AsyncExecutor.new

# --- Dev reloader ---
# Reloads changed sourced-ui lib files on each request.
# Domain files and reactor registrations are untouched.
class DevReloader
  LIB_DIR = File.expand_path('../../lib', __dir__)

  # Only reload component and router files.
  # Exclude dashboard.rb (has @@configuration side-effect) and version.rb.
  WATCH_GLOBS = [
    "#{LIB_DIR}/sourced/ui/components/**/*.rb",
    "#{LIB_DIR}/sourced/ui/dashboard/components/**/*.rb",
    "#{LIB_DIR}/sourced/ui/dashboard/app.rb",
  ].freeze

  def initialize(app)
    @app = app
    @mtimes = {}
  end

  def call(env)
    reload_changed_files
    @app.call(env)
  end

  private

  def reload_changed_files
    WATCH_GLOBS.each do |glob|
      Dir.glob(glob).each do |file|
        mtime = File.mtime(file)
        next if @mtimes[file] == mtime

        @mtimes[file] = mtime
        load file
      end
    end
  end
end

use DevReloader
run Sourced::UI::Dashboard
