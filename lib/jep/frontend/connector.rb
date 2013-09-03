require 'socket'
require 'tmpdir'
require 'jep/message_helper'

module JEP
module Frontend

class Connector
include Process
include JEP::MessageHelper

def initialize(config, message_handler, options={})
  @config = config
  @logger = options[:logger]
  @state = :off
  @message_handler = message_handler
  @connection_listener = options[:connect_callback]
  @outfile_provider = options[:outfile_provider]
  @keep_outfile = options[:keep_outfile]
  @connection_timeout = options[:connection_timeout] || 10
end

def send_message(type, object={}, binary="")
  if connected?
    object[:_message] = type
    msg = JEP::Message.new(object, binary)
    @logger.debug("sent: #{msg.inspect}") if @logger
    @socket.send(serialize_message(msg), 0)
    :success
  else
    connect unless connecting?
    do_work
    :connecting 
  end
end

def resume
  do_work
end

def stop
  while connecting?
    do_work
    sleep(0.1)
  end
  if connected?
    send_message(JEP::Message.new({:_message => "Stop"}))
    while do_work 
      sleep(0.1)
    end
  end
end

private

def connected?
  @state == :connected && backend_running?
end

def connecting?
  @state == :connecting
end

def backend_running?
  if @process_id
    begin
      return true unless waitpid(@process_id, Process::WNOHANG)
    rescue Errno::ECHILD
    end
  end
  false
end

def tempfile_name
  dir = Dir.tmpdir
  i = 0
  file = nil 
  while !file || File.exist?(file)
    file = dir+"/jep.temp.#{i}"
    i += 1
  end
  file
end

def connect
  @state = :connecting
  @connect_start_time = Time.now

  @logger.info "starting: #{@config.command}" if @logger

  if @outfile_provider
    @out_file = @outfile_provider.call
  else
    @out_file = tempfile_name 
  end
  @logger.debug "using output file #{@out_file}" if @logger
  File.unlink(@out_file) if File.exist?(@out_file)

  Dir.chdir(File.dirname(@config.file)) do
    @process_id = spawn(@config.command.strip + " > #{@out_file} 2>&1")
  end
  @work_state = :wait_for_file
end

def do_work
  case @work_state
  when :wait_for_file
    if File.exist?(@out_file)
      @work_state = :wait_for_port
    end
    if Time.now > @connect_start_time + @connection_timeout
      cleanup
      @connection_listener.call(:timeout) if @connection_listener
      @work_state = :done
      @state = :off
      @logger.warn "process didn't startup (connection timeout)" if @logger
    end
    true
  when :wait_for_port
    output = File.read(@out_file)
    if output =~ /^JEP service, listening on port (\d+)/
      port = $1.to_i
      @logger.info "connecting to #{port}" if @logger
      begin
        @socket = TCPSocket.new("127.0.0.1", port)
        @socket.setsockopt(:SOCKET, :RCVBUF, 1000000)
        @state = :connected
        @work_state = :read_from_socket
        @connection_listener.call(:connected) if @connection_listener
        @logger.info "connected" if @logger
      rescue Errno::ECONNREFUSED
        cleanup
        @connection_listener.call(:timeout) if @connection_listener
        @work_state = :done
        @state = :off
        @logger.warn "could not connect socket (connection refused)" if @logger
      end
    end
    if Time.now > @connect_start_time + @connection_timeout
      cleanup
      @connection_listener.call(:timeout) if @connection_listener
      @work_state = :done
      @state = :off
      @logger.warn "could not connect socket (connection timeout)" if @logger
    end
    true
  when :read_from_socket
    repeat = true
    socket_closed = false
    response_data = ""
    while repeat
      repeat = false
      data = nil
      begin
        data = @socket.read_nonblock(1000000)
      rescue Errno::EWOULDBLOCK
      rescue IOError, EOFError, Errno::ECONNRESET
        socket_closed = true
        @logger.info "server socket closed (end of file)" if @logger
      end
      if data
        repeat = true
        response_data.concat(data)
        while msg = extract_message(response_data)
          message_received(msg)
        end
      elsif !backend_running? || socket_closed
        cleanup
        @work_state = :done
        return false
      end
    end
    true
  end

end

def message_received(msg)
  reception_start = Time.now
  @logger.debug("received: "+msg.inspect) if @logger
  message_type = msg.object["_message"]
  if message_type
    handler_method = "handle_#{message_type}".to_sym
    if @message_handler.respond_to?(handler_method)
      @message_handler.send(handler_method, msg)
    else
      @logger.warn("can not handle message #{message_type}") if @logger
    end
  else
    @logger.warn("invalid message (no '_message' property)") if @logger
  end
  @logger.info("reception complete (#{Time.now-reception_start}s)") if @logger
end

def cleanup
  @socket.close if @socket
  # wait up to 5 seconds for backend to shutdown
  for i in 0..50 
    break unless backend_running?
    sleep(0.1)
  end
  File.unlink(@out_file) unless @keep_outfile
end

end

end
end


