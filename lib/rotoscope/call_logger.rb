# frozen_string_literal: true

require 'csv'

class Rotoscope
  class CallLogger
    class << self
      def trace(dest, class_whitelist: [], class_blacklist: [], path_blacklist: [])
        rs = new(dest, class_whitelist: class_whitelist, class_blacklist: [], path_blacklist: [])
        rs.trace { yield rs }
        rs
      ensure
        rs.io.close if rs && dest.is_a?(String)
      end
    end

    HEADER = "entity,caller_entity,filepath,lineno,method_name,method_level,caller_method_name,caller_method_level\n"

    attr_reader :io, :class_whitelist, :class_blacklist, :path_blacklist

    def initialize(output = nil, class_whitelist: nil, class_blacklist: nil, path_blacklist: nil)
      unless class_whitelist.is_a?(Regexp)
        class_whitelist = Regexp.union(class_whitelist || [])
      end
      @class_whitelist = class_whitelist

      unless class_blacklist.is_a?(Regexp)
        class_blacklist = Regexp.union(class_blacklist || [])
      end
      @class_blacklist = class_blacklist

      unless path_blacklist.is_a?(Regexp)
        path_blacklist = Regexp.union(path_blacklist || [])
      end
      @path_blacklist = path_blacklist

      if output.is_a?(String)
        @io = File.open(output, 'w')
        prevent_flush_from_finalizer_in_fork(@io)
      else
        @io = output
      end
      @output_buffer = ''.dup
      @pid = Process.pid
      @thread = Thread.current

      @io << HEADER

      @rotoscope = Rotoscope.new(&method(:log_call))
    end

    def trace
      start_trace
      yield
    ensure
      @rotoscope.stop_trace
    end

    def start_trace
      @rotoscope.start_trace
    end

    def stop_trace
      @rotoscope.stop_trace
    end

    def mark(message = "")
      was_tracing = @rotoscope.tracing?
      if was_tracing
        # stop tracing to avoid logging these io method calls
        @rotoscope.stop_trace
      end
      if @pid == Process.pid && @thread == Thread.current
        @io.write("--- ")
        @io.puts(message)
      end
    ensure
      @rotoscope.start_trace if was_tracing
    end

    def close
      @rotoscope.stop_trace
      if @pid == Process.pid && @thread == Thread.current
        @io.close
      end
      true
    end

    def closed?
      @io.closed?
    end

    def state
      return :closed if io.closed?
      @rotoscope.tracing? ? :tracing : :open
    end

    private

    def log_call(call)
      caller_path = call.caller_path || ''
      caller_class_name = call.caller_class_name || '<UNKNOWN>'

      return if self == call.receiver
      return if caller_class_name == call.receiver_class_name
      return if class_blacklist.match?(call.receiver_class_name) || class_blacklist.match?(caller_class_name)
      return unless class_whitelist.match?(call.receiver_class_name) || class_whitelist.match?(caller_class_name)
      return if path_blacklist.match?(caller_path)

      if call.caller_method_name.nil?
        caller_method_name = '<UNKNOWN>'
        caller_method_level = '<UNKNOWN>'
      else
        caller_method_name = escape_csv_string(call.caller_method_name)
        caller_method_level = call.caller_singleton_method? ? 'class' : 'instance'
      end

      call_method_level = call.singleton_method? ? 'class' : 'instance'
      method_name = escape_csv_string(call.method_name)

      buffer = @output_buffer
      buffer.clear
      buffer <<
        '"' << call.receiver_class_name << '",' \
        '"' << caller_class_name << '",' \
        '"' << caller_path << '",' \
        << call.caller_lineno.to_s << ',' \
        '"' << method_name << '",' \
        << call_method_level << ',' \
        '"' << caller_method_name << '",' \
        << caller_method_level << "\n"
      io.write(buffer)
    end

    def escape_csv_string(string)
      string.include?('"') ? string.gsub('"', '""') : string
    end

    def prevent_flush_from_finalizer_in_fork(io)
      pid = Process.pid
      finalizer = lambda do |_|
        next if Process.pid == pid
        # close the file descriptor from another IO object so
        # buffered writes aren't flushed
        IO.for_fd(io.fileno).close
      end
      ObjectSpace.define_finalizer(io, finalizer)
    end
  end
end
