# frozen_string_literal: true

require "semian/adapter"
require "active_record"

module Semian
  module ActiveRecordAdapter
    TRANSACTION_CLOSING_METHODS = [
      :commit_db_transaction,
      :exec_rollback_db_transaction,
      :exec_rollback_to_savepoint,
      :release_savepoint,
    ].freeze

    class << self
      def included(base)
        base.class_eval do
          attr_reader(:raw_semian_options, :semian_identifier)
        end
      end
    end

    def initialize(*options)
      *, config = options
      config = config.dup
      @raw_semian_options = config.delete(:semian)
      @semian_identifier = begin
        name = semian_options && semian_options[:name]
        unless name
          host = config[:host] || "localhost"
          port = config[:port] || semian_adapter_default_port
          name = "#{host}:#{port}"
        end
        :"#{semian_adapter_identifier_prefix}_#{name}"
      end
      super
    end

    if ActiveRecord.version >= Gem::Version.new("8.2.a")
      def execute_intent(intent)
        result = nil
        delivered_error = nil

        acquire_semian_resource(adapter: semian_adapter_name, scope: :query) do
          result = super

          # In Rails 8.2 execute_intent no longer raises errors. Instead, they are stored on the intent
          # and handled later by the caller to better enable asynchronous execution. However, we need to raise
          # any errors here to trip the circuit breaker. Then we can swallow the error and return the result for
          # Rails to continue with.
          if intent.respond_to?(:error)
            delivered_error = intent.error
            raise delivered_error if delivered_error
          end
        end
      rescue => error
        if error.equal?(delivered_error)
          result
        else
          raise
        end
      end
    else
      def raw_execute(sql, *args, **kwargs, &block)
        acquire_semian_resource(adapter: semian_adapter_name, scope: :query) do
          super(sql, *args, **kwargs, &block)
        end
      end
    end

    TRANSACTION_CLOSING_METHODS.each do |method|
      define_method(method) do |*args, **kwargs, &block|
        if resource_already_acquired?
          super(*args, **kwargs, &block)
        else
          mark_resource_as_acquired { super(*args, **kwargs, &block) }
        end
      end
    end

    def active?
      acquire_semian_resource(adapter: semian_adapter_name, scope: :ping) do
        super
      end
    rescue resource_busy_error_class, circuit_open_error_class
      false
    end

    def with_resource_timeout
      raise NotImplementedError, "#{self.class} must implement a `with_resource_timeout` method"
    end

    private

    def resource_exceptions
      [
        ActiveRecord::AdapterTimeout,
        ActiveRecord::ConnectionFailed,
        ActiveRecord::ConnectionNotEstablished,
      ]
    end

    def resource_busy_error_class
      self.class::ResourceBusyError
    end

    def circuit_open_error_class
      self.class::CircuitOpenError
    end

    def connect(*args)
      acquire_semian_resource(adapter: semian_adapter_name, scope: :connection) do
        super
      end
    end

    def semian_adapter_name
      raise NotImplementedError, "#{self.class} must implement an `semian_adapter_name` method"
    end

    def semian_adapter_default_port
      raise NotImplementedError, "#{self.class} must implement an `semian_adapter_default_port` method"
    end

    def semian_adapter_identifier_prefix
      raise NotImplementedError, "#{self.class} must implement an `semian_adapter_identifier_prefix` method"
    end
  end
end
