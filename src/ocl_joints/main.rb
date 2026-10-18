require 'sketchup.rb'
require 'fileutils'
require 'json'

module OclJoints

  PLUGIN_ROOT = File.dirname(__FILE__)
  SOURCE_FILES = %w[config joint scene tool].freeze
  CONFIG_FILE = File.join(ENV['APPDATA'] || Dir.home, 'ocl_joints', 'config.json')

  SOURCE_FILES.each { |f| require File.join(PLUGIN_ROOT, f) }

  # Connector table, shared by all models
  def self.config
    @config ||= File.exist?(CONFIG_FILE) ? Config.parse(File.read(CONFIG_FILE, encoding: 'UTF-8')) : Config.default
  end

  def self.save_config(config)
    @config = Config.normalize(config)
    FileUtils.mkdir_p(File.dirname(CONFIG_FILE))
    File.write(CONFIG_FILE, Config.dump(@config), encoding: 'UTF-8')
  end

  # Current connector row, kept between tool runs in this SketchUp session
  def self.row_index
    @row_index || 0
  end

  def self.row_index=(i)
    @row_index = i
  end

  def self.start_tool
    Sketchup.active_model.select_tool(JointTool.new)
  end

  def self.show_settings
    @dialog&.close
    @dialog = UI::HtmlDialog.new(dialog_title: 'OCL Joints: connectors', preferences_key: 'OclJointsSettings',
                                 width: 760, height: 520, style: UI::HtmlDialog::STYLE_DIALOG)
    @dialog.set_file(File.join(PLUGIN_ROOT, 'settings.html'))
    send = lambda do |config|
      defs = Sketchup.active_model.definitions.reject { |d| d.group? || d.image? }
      names = (defs.map(&:name) + defs.flat_map { |d| d.instances.map(&:name) })
              .map(&:strip).grep(/\A[fg]_/i).uniq.sort
      @dialog.execute_script("load(#{JSON.generate(Config.normalize(config))}, #{JSON.generate(names)})")
    end
    @dialog.add_action_callback('ready') { send.call(config) }
    @dialog.add_action_callback('save') do |_, json|
      save_config(Config.parse(json))
      @dialog.close
    rescue StandardError => e
      UI.messagebox("Settings not saved: #{e.message}")
    end
    @dialog.add_action_callback('cancel') { @dialog.close }
    @dialog.add_action_callback('defaults') { send.call(Config.default) }
    @dialog.add_action_callback('browse') do
      folder = UI.select_directory(title: 'Library folder with component .skp files')
      @dialog.execute_script("addFolder(#{JSON.generate(folder.tr('\\', '/'))})") if folder
    end
    @dialog.add_action_callback('import') do
      path = UI.openpanel('Import connectors', '', 'JSON|*.json||')
      send.call(Config.parse(File.read(path, encoding: 'UTF-8'))) if path
    end
    @dialog.add_action_callback('export') do |_, json|
      path = UI.savepanel('Export connectors', '', 'ocl_joints.json')
      if path
        path += '.json' unless path.downcase.end_with?('.json')
        File.write(path, Config.dump(Config.parse(json)), encoding: 'UTF-8')
      end
    end
    @dialog.show
  end

  # Development helper: reload source files without restarting SketchUp.
  def self.reload
    SOURCE_FILES.each { |f| load File.join(PLUGIN_ROOT, "#{f}.rb") }
    puts 'OCL Joints reloaded'
  end

  unless file_loaded?(__FILE__)
    joints = UI::Command.new('Joints') { start_tool }
    joints.tooltip = 'Joints'
    joints.status_bar_text = 'Select, move, copy and erase connector pairs; hold Alt and click two panels to add a pair'
    joints.small_icon = joints.large_icon = File.join(PLUGIN_ROOT, 'icons', 'joints.svg')
    settings = UI::Command.new('Settings...') { show_settings }
    settings.tooltip = 'OCL Joints settings'
    settings.status_bar_text = 'Edit the connector table and the library folders'
    settings.small_icon = settings.large_icon = File.join(PLUGIN_ROOT, 'icons', 'settings.svg')

    menu = UI.menu('Extensions').add_submenu('OCL Joints')
    menu.add_item(joints)
    menu.add_item(settings)
    menu.add_separator
    menu.add_item('Reload extension (dev)') { reload }

    toolbar = UI::Toolbar.new('OCL Joints')
    toolbar.add_item(joints)
    toolbar.add_item(settings)
    toolbar.restore

    file_loaded(__FILE__)
  end

end
