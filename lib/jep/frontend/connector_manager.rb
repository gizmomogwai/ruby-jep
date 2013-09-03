require 'digest'
require 'jep/config'
require 'jep/frontend/connector'

module JEP
module Frontend

# A ConnectorManager provides Connectors for files being edited.
# It starts the connectors if necessary and keeps track of them in order to reuse them.
# When a config file changes, all affected connectors are restarted on the next request.
#
class ConnectorManager

def initialize(message_handler, options={})
  @message_handler = message_handler
  @logger = options[:logger]
  @connector_descs = {}
  @connector_listener = options[:connect_callback]
  @keep_outfile = options[:keep_outfile]
  @outfile_provider = options[:outfile_provider]
  @connection_timeout = options[:connection_timeout]
end

ConnectorDesc = Struct.new(:connector, :checksum)

def connector_for_file(file)
  config = Config.find_service_config(file)
  if config
    file_pattern = Config.file_pattern(file)
    key = desc_key(config, file_pattern)
    desc = @connector_descs[key]
    if desc
      if desc.checksum == config_checksum(config)
        desc.connector
      else
        # connector must be replaced
        desc.connector.stop
        create_connector(config, file_pattern) 
      end
    else
      create_connector(config, file_pattern)
    end
  else
    nil
  end
end

def all_connectors
  @connector_descs.values.collect{|v| v.connector}
end

private

def create_connector(config, pattern)
  con = Connector.new(config, @message_handler,
    :logger => @logger, :keep_outfile => @keep_outfile,
    :outfile_provider => @outfile_provider,
    :connection_timeout => @connection_timeout,
    :connect_callback => lambda do |state|
      @connector_listener.call(con, state) if @connector_listener
    end)
  desc = ConnectorDesc.new(con, config_checksum(config))
  key = desc_key(config, pattern)
  @connector_descs[key] = desc
  desc.connector
end

def desc_key(config, pattern)
  config.file.downcase + "," + pattern
end

def config_checksum(config)
  if File.exist?(config.file)
    sha1 = Digest::SHA1.new
    sha1.file(config.file)
    sha1.hexdigest
  else
    nil
  end
end


end

end
end

