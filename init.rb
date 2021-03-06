Redmine::Plugin.register :microsoft_project_connector do
  name 'Microsoft Project Connector'
  author 'Chen Wei'
  description 'This is a plugin for Redmine'
  version '0.0.1'
  url 'http://example.com/path/to/plugin'
  author_url 'http://example.com/about'

  permission :microsoft_project_connector_setting, { :microsoft_project_connector => [:setting] }, :public => true
  permission :microsoft_project_connector_using, { :microsoft_project_connector => [:query] }, :public => true

  menu :admin_menu, :microsoft_project_connector, {:controller => 'settings', :action => 'plugin', :id => "microsoft_project_connector"}, :html => {:class => 'icon icon-ms-project'}, :caption => :microsoft_project_connector, :if => Proc.new { User.current.admin? || User.current.module_permissions.include?('microsoft_project_connector_setting') }
                      
  settings :default => {
  }, :partial => 'settings/index'

end


if defined? ActionDispatch::Callbacks.to_prepare
  ActionDispatch::Callbacks.to_prepare do
    require 'microsoft_project_connector'
  end
else
  ActiveSupport::Reloader.to_prepare do
    require 'microsoft_project_connector'
  end
end