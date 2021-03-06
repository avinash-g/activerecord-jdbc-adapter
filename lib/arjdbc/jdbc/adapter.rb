require 'active_record/version'
require 'active_record/connection_adapters/abstract_adapter'

require 'arjdbc/version'
require 'arjdbc/jdbc/java'
require 'arjdbc/jdbc/base_ext'
require 'arjdbc/jdbc/error'
require 'arjdbc/jdbc/connection_methods'
require 'arjdbc/jdbc/column'
require 'arjdbc/jdbc/connection'
require 'arjdbc/jdbc/arel_support'
require 'arjdbc/jdbc/callbacks'
require 'arjdbc/jdbc/extension'

module ActiveRecord
  module ConnectionAdapters

    autoload :JdbcDriver, 'arjdbc/jdbc/driver' # compatibility - no longer used
    autoload :JdbcTypeConverter, 'arjdbc/jdbc/type_converter'

    # Built on top of `ActiveRecord::ConnectionAdapters::AbstractAdapter` which
    # provides the abstract interface for database-specific functionality, this
    # class serves 2 purposes in AR-JDBC :
    # - as a base class for sub-classes
    # - usable standalone (or with a mixed in adapter spec module)
    #
    # Historically this class is mostly been used standalone and that's still a
    # valid use-case esp. since (with it's `arjdbc.jdbc.RubyJdbcConnectionClass`)
    # JDBC provides a unified interface for all databases in Java it tries to do
    # it's best implementing all `ActiveRecord` functionality on top of that.
    # This might no be perfect that's why it checks for a `config[:adapter_spec]`
    # module (or tries to resolve one from the JDBC driver's meta-data) and if
    # the database has "extended" AR-JDBC support mixes in the given module for
    # each adapter instance.
    # This is sufficient for most database specific specs we support, but for
    # compatibility with native (MRI) adapters it's perfectly fine to sub-class
    # the adapter and override some of its API methods.
    class JdbcAdapter < AbstractAdapter
      extend ShadowCoreMethods

      include Jdbc::ArelSupport
      include Jdbc::ConnectionPoolCallbacks

      attr_reader :config

      def self.new(connection, logger = nil, pool = nil)
        adapter = super
        Jdbc::JndiConnectionPoolCallbacks.prepare(adapter, adapter.instance_variable_get(:@connection))
        adapter
      end

      # Initializes the (JDBC connection) adapter instance.
      # The passed configuration Hash's keys are symbolized, thus changes to
      # the original `config` keys won't be reflected in the adapter.
      # If the adapter's sub-class or the spec module that this instance will
      # extend in responds to `configure_connection` than it will be called.
      # @param connection an (optional) connection instance
      # @param logger the `ActiveRecord::Base.logger` to use (or nil)
      # @param config the database configuration
      # @note `initialize(logger, config)` with 2 arguments is supported as well
      def initialize(connection, logger, config = nil); pool = nil
        if config.nil?
          if logger.respond_to?(:key?) # (logger, config)
            config, logger, connection = logger, connection, nil
          else
            config = connection.respond_to?(:config) ?
              connection.config : ActiveRecord::Base.connection_pool.spec.config
          end
        elsif config.respond_to?(:spec) && config.respond_to?(:connection)
          pool = config; config = pool.spec.config # AR >= 3.2 compatibility
        end

        @config = config.respond_to?(:symbolize_keys) ? config.symbolize_keys : config

        if self.class.equal? JdbcAdapter
          spec = @config.key?(:adapter_spec) ? @config[:adapter_spec] :
            ( @config[:adapter_spec] = adapter_spec(@config) ) # due resolving visitor
          extend spec if spec
        end

        # NOTE: adapter spec's init_connection only called if instantiated here :
        connection ||= jdbc_connection_class(spec).new(@config, self)

        pool.nil? ? super(connection, logger) : super(connection, logger, pool)

        connection.configure_connection # will call us (maybe)

        @visitor = new_visitor # nil if no AREL (AR-2.3)
      end

      # By convention sub-adapters are expected to export a JDBC connection
      # type they wish the adapter instantiates on {#initialize} by default.
      # @since 1.4.0
      JdbcConnection = ::ActiveRecord::ConnectionAdapters::JdbcConnection

      # Returns the (JDBC) connection class to be used for this adapter.
      # This is used by (database specific) spec modules to override the class
      # used assuming some of the available methods have been re-defined.
      # @see ActiveRecord::ConnectionAdapters::JdbcConnection
      def self.jdbc_connection_class(spec)
        connection_class = spec.jdbc_connection_class if spec && spec.respond_to?(:jdbc_connection_class)
        connection_class ? connection_class : self::JdbcConnection
      end

      # @note The spec argument passed is ignored and shall no longer be used.
      # @see ActiveRecord::ConnectionAdapters::JdbcConnection#jdbc_connection_class
      def jdbc_connection_class(spec = nil)
        spec ? self.class.jdbc_connection_class(spec) : self.class::JdbcConnection
      end

      # Returns the (JDBC) `ActiveRecord` column class for this adapter.
      # This is used by (database specific) spec modules to override the class.
      # @see ActiveRecord::ConnectionAdapters::JdbcColumn
      def jdbc_column_class
        return self.class::Column if self.class.const_defined?(:Column)
        ::ActiveRecord::ConnectionAdapters::JdbcColumn # TODO auto-load
      end

      # @private Simple fix for keeping 1.8 compatibility.
      def jdbc_column_class
        column = self.class::Column rescue nil
        return column if column
        ::ActiveRecord::ConnectionAdapters::JdbcColumn # TODO auto-load
      end if RUBY_VERSION < '1.9'

      # Retrieve the raw `java.sql.Connection` object.
      # The unwrap parameter is useful if an attempt to unwrap a pooled (JNDI)
      # connection should be made - to really return the 'native' JDBC object.
      # @param unwrap [true, false] whether to unwrap the connection object
      # @return [Java::JavaSql::Connection] the JDBC connection
      def jdbc_connection(unwrap = nil)
        raw_connection.jdbc_connection(unwrap)
      end

      # Locate the specialized (database specific) adapter specification module
      # if one exists based on provided configuration data. This module will than
      # extend an instance of the adapter (unless an `:adapter_class` provided).
      #
      # This method is called during {#initialize} unless an explicit
      # `config[:adapter_spec]` is set.
      # @param config the configuration to check for `:adapter_spec`
      # @return [Module] the database specific module
      def adapter_spec(config)
        dialect = ( config[:dialect] || config[:driver] ).to_s
        ::ArJdbc.modules.each do |constant| # e.g. ArJdbc::MySQL
          if constant.respond_to?(:adapter_matcher)
            spec = constant.adapter_matcher(dialect, config)
            return spec if spec
          end
        end

        unless config.key?(:dialect)
          begin # does nothing unless config[:jndi] || config[:data_source]
            dialect = ::ArJdbc.with_meta_data_from_data_source_if_any(config) do
              |meta_data| config[:dialect] = meta_data.getDatabaseProductName
            end
            return adapter_spec(config) if dialect # re-try matching with :dialect
          rescue => e
            ::ArJdbc.warn("failed to set :dialect from database meda-data: #{e}")
          end
        end

        nil
      end

      ADAPTER_NAME = 'JDBC'.freeze

      # @return [String] the 'JDBC' adapter name.
      def adapter_name
        ADAPTER_NAME
      end

      # Will return true even when native adapter classes passed in
      # e.g. `jdbc_adapter.is_a? ConnectionAdapter::PostgresqlAdapter`
      #
      # This is only necessary (for built-in adapters) when
      # `config[:adapter_class]` is forced to `nil` and the `:adapter_spec`
      # module is used to extend the `JdbcAdapter`, otherwise we replace the
      # class constants for built-in adapters (MySQL, PostgreSQL and SQLite3).
      # @override
      # @private
      def is_a?(klass)
        # This is to fake out current_adapter? conditional logic in AR tests
        if klass.is_a?(Class) && klass.name =~ /#{adapter_name}Adapter$/i
          true
        else
          super
        end
      end

      # If there's a `self.arel2_visitors(config)` method on the adapter
      # spec than it is preferred and will be used instead of this one.
      # @return [Hash] the AREL visitor to use
      # @deprecated No longer used.
      # @see ActiveRecord::ConnectionAdapters::Jdbc::ArelSupport
      def self.arel2_visitors(config)
        { 'jdbc' => ::Arel::Visitors::ToSql }
      end

      # @see ActiveRecord::ConnectionAdapters::JdbcAdapter#arel2_visitors
      # @deprecated No longer used.
      def self.configure_arel2_visitors(config)
        visitors = ::Arel::Visitors::VISITORS
        klass = config[:adapter_spec]
        klass = self unless klass.respond_to?(:arel2_visitors)
        visitor = nil
        klass.arel2_visitors(config).each do |name, arel|
          visitors[name] = ( visitor = arel )
        end
        if visitor && config[:adapter] =~ /^(jdbc|jndi)$/
          visitors[ config[:adapter] ] = visitor
        end
        visitor
      end

      # DB specific types are detected but adapter specs (or extenders) are
      # expected to hand tune these types for concrete databases.
      # @return [Hash] the native database types
      # @override
      def native_database_types
        @native_database_types ||= begin
          types = @connection.native_database_types
          modify_types(types)
          types
        end
      end

      # @override introduced in AR 4.2
      def valid_type?(type)
        ! native_database_types[type].nil?
      end

      # Allows for modification of the detected native types.
      # @param types the resolved native database types
      # @see #native_database_types
      def modify_types(types)
        types
      end

      # Abstract adapter default implementation does nothing silently.
      # @override
      def structure_dump
        raise NotImplementedError, "structure_dump not supported"
      end

      # JDBC adapters support migration.
      # @return [true]
      # @override
      def supports_migrations?
        true
      end

      # Returns the underlying database name.
      # @override
      def database_name
        @connection.database_name
      end

      # @override
      def active?
        return false unless @connection
        @connection.active?
      end

      # @override
      def reconnect!
        super # clear_cache! && reset_transaction
        @connection.reconnect! # handles adapter.configure_connection
        @connection
      end

      # @override
      def disconnect!
        super # clear_cache! && reset_transaction
        return unless @connection
        @connection.disconnect!
      end

      # @override
      #def verify!(*ignored)
      #  if @connection && @connection.jndi?
      #    # checkout call-back does #reconnect!
      #  else
      #    reconnect! unless active? # super
      #  end
      #end

      if ActiveRecord::VERSION::MAJOR < 3

        # @private
        def jdbc_insert(sql, name = nil, pk = nil, id_value = nil, sequence_name = nil)
          insert_sql(sql, name, pk, id_value, sequence_name)
        end
        alias_chained_method :insert, :query_dirty, :jdbc_insert

        # @private
        def jdbc_update(sql, name = nil, binds = [])
          execute(sql, name, binds)
        end
        alias_chained_method :update, :query_dirty, :jdbc_update

        # @private
        def jdbc_select_all(sql, name = nil, binds = [])
          select(sql, name, binds)
        end
        alias_chained_method :select_all, :query_cache, :jdbc_select_all

      end

      # @note Used on AR 2.3 and 3.0
      # @override
      def insert_sql(sql, name = nil, pk = nil, id_value = nil, sequence_name = nil)
        id = execute(sql, name)
        id_value || id
      end

      def columns(table_name, name = nil)
        @connection.columns(table_name.to_s)
      end

      # Starts a database transaction.
      # @override
      def begin_db_transaction
        @connection.begin
      end

      # Commits the current database transaction.
      # @override
      def commit_db_transaction
        @connection.commit
      end

      # Rolls back the current database transaction.
      # @override
      def rollback_db_transaction
        @connection.rollback
      end

      # Starts a database transaction.
      # @param isolation the transaction isolation to use
      # @since 1.3.0
      # @override on **AR-4.0**
      def begin_isolated_db_transaction(isolation)
        @connection.begin(isolation)
      end

      # Does this adapter support setting the isolation level for a transaction?
      # Unlike 'plain' `ActiveRecord` we allow checking for concrete transaction
      # isolation level support by the database.
      # @param level optional to check if we support a specific isolation level
      # @since 1.3.0
      # @extension added optional level parameter
      def supports_transaction_isolation?(level = nil)
        @connection.supports_transaction_isolation?(level)
      end

      # Does our database (+ its JDBC driver) support save-points?
      # @since 1.3.0
      # @override
      def supports_savepoints?
        @connection.supports_savepoints?
      end

      # Creates a (transactional) save-point one can rollback to.
      # Unlike 'plain' `ActiveRecord` it is allowed to pass a save-point name.
      # @param name the save-point name
      # @return save-point name (even if nil passed will be generated)
      # @since 1.3.0
      # @extension added optional name parameter
      def create_savepoint(name = current_savepoint_name(true))
        @connection.create_savepoint(name)
      end

      # Transaction rollback to a given (previously created) save-point.
      # If no save-point name given rollback to the last created one.
      # @param name the save-point name
      # @since 1.3.0
      # @extension added optional name parameter
      def rollback_to_savepoint(name = current_savepoint_name(true))
        @connection.rollback_savepoint(name)
      end

      # Release a previously created save-point.
      # @note Save-points are auto-released with the transaction they're created
      # in (on transaction commit or roll-back).
      # @param name the save-point name
      # @since 1.3.0
      # @extension added optional name parameter
      def release_savepoint(name = current_savepoint_name(false))
        @connection.release_savepoint(name)
      end

      # Due tracking of save-points created in a LIFO manner, always returns
      # the correct name if any (last) save-point has been marked and not released.
      # Otherwise when creating a save-point same naming convention as
      # `ActiveRecord` uses ("active_record_" prefix) will be returned.
      # @return [String] the current save-point name
      # @since 1.3.0
      # @override
      def current_savepoint_name(compat = true)
        open_tx = open_transactions
        return "active_record_#{open_tx}" if compat # by default behave like AR

        sp_names = @connection.marked_savepoint_names
        sp_names.last || "active_record_#{open_tx}"
        # should (open_tx- 1) here but we play by AR's rules as it might fail
      end unless ArJdbc::AR42

      # @note Same as AR 4.2 but we're allowing an unused parameter.
      # @private
      def current_savepoint_name(compat = nil)
        current_transaction.savepoint_name # unlike AR 3.2-4.1 might be nil
      end if ArJdbc::AR42

      # @override
      def supports_views?
        @connection.supports_views?
      end

      # AR-JDBC extension that allows you to have read-only connections.
      # Read-only connection do not allow any inserts/updates, such operations fail.
      # @return [Boolean] whether the underlying conn is read-only (false by default)
      # @since 1.4.0
      def read_only?
        @connection.read_only?
      end

      # AR-JDBC extension that allows you to have read-only connections.
      # @param flag the read-only flag to set
      # @see #read_only?
      # @since 1.4.0
      def read_only=(flag)
        @connection.read_only = flag
      end

      # Executes a SQL query in the context of this connection using the bind
      # substitutes.
      # @param sql the query string (or AREL object)
      # @param name logging marker for the executed SQL statement log entry
      # @param binds the bind parameters
      # @return [ActiveRecord::Result] or [Array] on **AR-2.3**
      # @override available since **AR-3.1**
      def exec_query(sql, name = 'SQL', binds = [])
        if sql.respond_to?(:to_sql)
          sql = to_sql(sql, binds); to_sql = true
        end
        if prepared_statements?
          log(sql, name, binds) { @connection.execute_query(sql, binds) }
        else
          sql = suble_binds(sql, binds) unless to_sql # deprecated behavior
          log(sql, name) { @connection.execute_query(sql) }
        end
      end

      # Executes an insert statement in the context of this connection.
      # @param sql the query string (or AREL object)
      # @param name logging marker for the executed SQL statement log entry
      # @param binds the bind parameters
      # @override available since **AR-3.1**
      def exec_insert(sql, name, binds, pk = nil, sequence_name = nil)
        if sql.respond_to?(:to_sql)
          sql = to_sql(sql, binds); to_sql = true
        end
        if prepared_statements?
          log(sql, name || 'SQL', binds) { @connection.execute_insert(sql, binds) }
        else
          sql = suble_binds(sql, binds) unless to_sql # deprecated behavior
          log(sql, name || 'SQL') { @connection.execute_insert(sql) }
        end
      end

      # Executes a delete statement in the context of this connection.
      # @param sql the query string (or AREL object)
      # @param name logging marker for the executed SQL statement log entry
      # @param binds the bind parameters
      # @override available since **AR-3.1**
      def exec_delete(sql, name, binds)
        if sql.respond_to?(:to_sql)
          sql = to_sql(sql, binds); to_sql = true
        end
        if prepared_statements?
          log(sql, name || 'SQL', binds) { @connection.execute_delete(sql, binds) }
        else
          sql = suble_binds(sql, binds) unless to_sql # deprecated behavior
          log(sql, name || 'SQL') { @connection.execute_delete(sql) }
        end
      end

      # # Executes an update statement in the context of this connection.
      # @param sql the query string (or AREL object)
      # @param name logging marker for the executed SQL statement log entry
      # @param binds the bind parameters
      # @override available since **AR-3.1**
      def exec_update(sql, name, binds)
        if sql.respond_to?(:to_sql)
          sql = to_sql(sql, binds); to_sql = true
        end
        if prepared_statements?
          log(sql, name || 'SQL', binds) { @connection.execute_update(sql, binds) }
        else
          sql = suble_binds(sql, binds) unless to_sql # deprecated behavior
          log(sql, name || 'SQL') { @connection.execute_update(sql) }
        end
      end

      # Similar to {#exec_query} except it returns "raw" results in an array
      # where each rows is a hash with keys as columns (just like Rails used to
      # do up until 3.0) instead of wrapping them in a {#ActiveRecord::Result}.
      # @param sql the query string (or AREL object)
      # @param name logging marker for the executed SQL statement log entry
      # @param binds the bind parameters
      # @yield [v1, v2] depending on the row values returned from the query
      # In case a block is given it will yield each row from the result set
      # instead of returning mapped query results in an array.
      # @return [Array] unless a block is given
      def exec_query_raw(sql, name = 'SQL', binds = [], &block)
        if sql.respond_to?(:to_sql)
          sql = to_sql(sql, binds); to_sql = true
        end
        if prepared_statements?
          log(sql, name, binds) { @connection.execute_query_raw(sql, binds, &block) }
        else
          sql = suble_binds(sql, binds) unless to_sql # deprecated behavior
          log(sql, name) { @connection.execute_query_raw(sql, &block) }
        end
      end

      # @private
      # @override
      def select_rows(sql, name = nil, binds = [])
        exec_query_raw(sql, name, binds).map!(&:values)
      end

      if ActiveRecord::VERSION::MAJOR > 3 # expects AR::Result e.g. from select_all

      # @private
      def select(sql, name = nil, binds = [])
        exec_query(to_sql(sql, binds), name, binds)
      end

      else

      # @private
      def select(sql, name = nil, binds = []) # NOTE: only (sql, name) on AR < 3.1
        exec_query_raw(to_sql(sql, binds), name, binds)
      end

      end

      # Executes the SQL statement in the context of this connection.
      # The return value from this method depends on the SQL type (whether
      # it's a SELECT, INSERT etc.). For INSERTs a generated id might get
      # returned while for UPDATE statements the affected row count.
      # Please note that this method returns "raw" results (in an array) for
      # statements that return a result set, while {#exec_query} is expected to
      # return a `ActiveRecord::Result` (since AR 3.1).
      # @note This method does not use prepared statements.
      # @note The method does not emulate various "native" `execute` results on MRI.
      # @see #exec_query
      # @see #exec_insert
      # @see #exec_update
      def execute(sql, name = nil, binds = nil)
        sql = suble_binds to_sql(sql, binds), binds if binds
        if name == :skip_logging
          _execute(sql, name)
        else
          log(sql, name) { _execute(sql, name) }
        end
      end

      # @private documented above
      def execute(sql, name = nil, skip_logging = false)
        if skip_logging.is_a?(Array)
          binds, skip_logging = skip_logging, false
          sql = suble_binds to_sql(sql, binds), binds
        end
        if skip_logging || name == :skip_logging
          _execute(sql, name)
        else
          log(sql, name) { _execute(sql, name) }
        end
      end if ActiveRecord::VERSION::MAJOR < 3 ||
        ( ActiveRecord::VERSION::MAJOR == 3 && ActiveRecord::VERSION::MINOR == 0 )

      # We need to do it this way, to allow Rails stupid tests to always work
      # even if we define a new `execute` method. Instead of mixing in a new
      # `execute`, an `_execute` should be mixed in.
      # @deprecated it was only introduced due tests
      # @private
      def _execute(sql, name = nil)
        @connection.execute(sql)
      end
      private :_execute

      # Kind of `execute(sql) rescue nil` but logging failures at debug level only.
      def execute_quietly(sql, name = 'SQL')
        log(sql, name) do
          begin
            _execute(sql)
          rescue => e
            logger.debug("#{e.class}: #{e.message}: #{sql}")
          end
        end
      end

      # @override
      def tables(name = nil)
        @connection.tables
      end

      # @override
      def table_exists?(name)
        return false unless name
        @connection.table_exists?(name) # schema_name = nil
      end

      # @override
      def data_sources
        tables
      end if ArJdbc::AR42

      # @override
      def data_source_exists?(name)
        table_exists?(name)
      end if ArJdbc::AR42

      # @override
      def indexes(table_name, name = nil, schema_name = nil)
        @connection.indexes(table_name, name, schema_name)
      end

      # @override
      def pk_and_sequence_for(table)
        ( key = primary_key(table) ) ? [ key, nil ] : nil
      end

      # @override
      def primary_key(table)
        primary_keys(table).first
      end

      # @override
      def primary_keys(table)
        @connection.primary_keys(table)
      end

      # @override
      def foreign_keys(table_name)
        @connection.foreign_keys(table_name)
      end if ArJdbc::AR42

      # Does our database (+ its JDBC driver) support foreign-keys?
      # @since 1.3.18
      # @override
      def supports_foreign_keys?
        @connection.supports_foreign_keys?
      end if ArJdbc::AR42

      # @deprecated Rather use {#update_lob_value} instead.
      def write_large_object(*args)
        @connection.write_large_object(*args)
      end

      # @param record the record e.g. `User.find(1)`
      # @param column the model's column e.g. `User.columns_hash['photo']`
      # @param value the lob value - string or (IO or Java) stream
      def update_lob_value(record, column, value)
        @connection.update_lob_value(record, column, value)
      end

      if ActiveRecord::VERSION::MAJOR == 3 && ActiveRecord::VERSION::MINOR == 0

        #attr_reader :visitor unless method_defined?(:visitor) # not in 3.0

        # @private
        def to_sql(arel, binds = nil)
          # NOTE: can not handle `visitor.accept(arel.ast)` right
          arel.respond_to?(:to_sql) ? arel.send(:to_sql) : arel
        end

      elsif ActiveRecord::VERSION::MAJOR < 3 # AR-2.3 'fake' #to_sql method

        # @private
        def to_sql(sql, binds = nil)
          sql
        end

      end

      protected

      # @override so that we do not have to care having 2 arguments on 3.0
      def log(sql, name = nil, binds = [])
        unless binds.blank?
          binds = binds.map do |column, value|
            column ? [column.name, value] : [nil, value]
          end
          sql = "#{sql} #{binds.inspect}"
        end
        super(sql, name || 'SQL') # `log(sql, name)` on AR <= 3.0
      end if ::ActiveRecord::VERSION::MAJOR < 3 ||
        ( ::ActiveRecord::VERSION::MAJOR == 3 && ::ActiveRecord::VERSION::MINOR < 1 )

      if ::ActiveRecord::VERSION::MAJOR > 3
        # @private
        WrappingStatementInvalid = ::ActiveRecord::StatementInvalid
      elsif ::ActiveRecord::VERSION::MAJOR > 2
        # @private AR 3.x : WrappedDatabaseException < StatementInvalid
        WrappingStatementInvalid = ::ActiveRecord::WrappedDatabaseException
      else # 2.3
        # does not have a translate_exception but does this in log :
        #   raise ActiveRecord::StatementInvalid, message
        #
        # NOTE: still suitable to patch due JDBCError assuming super(msg, cause)
        ::ActiveRecord::StatementInvalid.class_eval do
          # attr_reader :original_exception
          def initialize(message, original_exception = nil)
            super(message)
            @original_exception = original_exception
          end
        end
        # @private
        WrappingStatementInvalid = ::ActiveRecord::StatementInvalid
      end

      def translate_exception(e, message)
        return e if e.is_a?(JDBCError)
        # we shall not translate native "Java" exceptions as they might
        # swallow an ArJdbc / driver bug into a AR::StatementInvalid ...
        return e if e.is_a?(NativeException) # JRuby 1.6
        return e if e.is_a?(Java::JavaLang::Throwable)

        case e
        when SystemExit, SignalException, NoMemoryError then e
        else WrappingStatementInvalid.new(message, e) # super
        end
      end

      # Take an id from the result of an INSERT query.
      # @return [Integer, NilClass]
      def last_inserted_id(result)
        if result.is_a?(Hash) || result.is_a?(ActiveRecord::Result)
          result.first.first[1] # .first = { "id"=>1 } .first = [ "id", 1 ]
        else
          result
        end
      end

      # @private
      def last_inserted_id(result)
        if result.is_a?(Hash)
          result.first.first[1] # .first = { "id"=>1 } .first = [ "id", 1 ]
        else
          result
        end
      end unless defined? ActiveRecord::Result

      # NOTE: make sure if adapter overrides #table_definition that it will
      # work on AR 3.x as well as 4.0
      if ActiveRecord::VERSION::MAJOR > 3

      # aliasing #create_table_definition as #table_definition :
      alias table_definition create_table_definition

      # `TableDefinition.new native_database_types, name, temporary, options`
      # and ActiveRecord 4.1 supports optional `as` argument (which defaults
      # to nil) to provide the SQL to use to generate the table:
      # `TableDefinition.new native_database_types, name, temporary, options, as`
      # @private
      def create_table_definition(*args)
        table_definition(*args)
      end

      # @note AR-4x arguments expected: `(name, temporary, options)`
      # @private documented bellow
      def new_table_definition(table_definition, *args)
        table_definition.new native_database_types, *args
      end
      private :new_table_definition

      # @private
      def new_index_definition(table, name, unique, columns, lengths,
          orders = nil, where = nil, type = nil, using = nil)
        IndexDefinition.new(table, name, unique, columns, lengths, orders, where, type, using)
      end
      private :new_index_definition

      #

      # Provides backwards-compatibility on ActiveRecord 4.1 for DB adapters
      # that override this and than call super expecting to work.
      # @note This method is available in 4.0 but won't be in 4.1
      # @private
      def add_column_options!(sql, options)
        sql << " DEFAULT #{quote(options[:default], options[:column])}" if options_include_default?(options)
        # must explicitly check for :null to allow change_column to work on migrations
        sql << " NOT NULL" if options[:null] == false
        sql << " AUTO_INCREMENT" if options[:auto_increment] == true
      end
      public :add_column_options!

      else # AR < 4.0

      # Helper to easily override #table_definition (on AR 3.x/4.0) as :
      # ```
      #   def table_definition(*args)
      #     new_table_definition(TableDefinition, *args)
      #   end
      # ```
      def new_table_definition(table_definition, *args)
        table_definition.new(self) # args ignored only used for 4.0
      end
      private :new_table_definition

      # @private (:table, :name, :unique, :columns, :lengths, :orders)
      def new_index_definition(table, name, unique, columns, lengths,
          orders = nil, where = nil, type = nil, using = nil)
        IndexDefinition.new(table, name, unique, columns, lengths, orders)
      end
      # @private (:table, :name, :unique, :columns, :lengths)
      def new_index_definition(table, name, unique, columns, lengths,
          orders = nil, where = nil, type = nil, using = nil)
        IndexDefinition.new(table, name, unique, columns, lengths)
      end if ActiveRecord::VERSION::STRING < '3.2'
      private :new_index_definition

      end

      # @return whether `:prepared_statements` are to be used
      def prepared_statements?
        return @prepared_statements unless (@prepared_statements ||= nil).nil?
        @prepared_statements = self.class.prepared_statements?(config)
      end

      # Allows changing the prepared statements setting for this connection.
      # @see #prepared_statements?
      #def prepared_statements=(statements)
      #  @prepared_statements = statements
      #end

      def self.prepared_statements?(config)
        config.key?(:prepared_statements) ?
          type_cast_config_to_boolean(config.fetch(:prepared_statements)) :
            false # off by default - NOTE: on AR 4.x it's on by default !?
      end

      if @@suble_binds = ENV_JAVA['arjdbc.adapter.suble_binds']
        @@suble_binds = Java::JavaLang::Boolean.parseBoolean(@@suble_binds)
      else
        @@suble_binds = ActiveRecord::VERSION::MAJOR < 4 # due compatibility
      end
      # @deprecated
      def self.suble_binds?; @@suble_binds; end

      private

      # @note Since AR 4.0 we (finally) do not "sub" SQL's '?' parameters !
      # @deprecated expected to go away in a future version that drops AR 3.2
      def suble_binds(sql, binds)
        return sql if ! @@suble_binds || binds.nil? || binds.empty?
        binds = binds.dup; warn = nil
        result = sql.gsub('?') { warn = true; quote(*binds.shift.reverse) }
        ActiveSupport::Deprecation.warn(
          "string binds substitution is deprecated - please refactor your sql", caller[1..-1]
        ) if warn
        result
      end

      # @private Supporting "string-subling" on AR 4.0 would require {#to_sql}
      # to consume binds parameters otherwise it happens twice e.g. for a record
      # insert it is called during {#insert} as well as on {#exec_insert} ...
      # but that than leads to other issues with libraries that save the binds
      # array and run a query again since it's the very same instance on 4.0 !
      def suble_binds(sql, binds)
        sql
      end if ActiveRecord::VERSION::MAJOR > 3

      # @deprecated No longer used, will be removed.
      # @see #suble_binds
      def substitute_binds(sql, binds)
        return sql if binds.nil? || binds.empty?; binds = binds.dup
        extract_sql(sql).gsub('?') { quote(*binds.shift.reverse) }
      end

      # @deprecated No longer used, kept for 1.2 API compatibility.
      def extract_sql(arel)
        arel.respond_to?(:to_sql) ? arel.send(:to_sql) : arel
      end

      if ActiveRecord::VERSION::MAJOR > 2
        # Helper useful during {#quote} since AREL might pass in it's literals
        # to be quoted, fixed since AREL 4.0.0.beta1 : http://git.io/7gyTig
        def sql_literal?(value); ::Arel::Nodes::SqlLiteral === value; end
      else
        # @private
        def sql_literal?(value); false; end
      end

      # Helper to get local/UTC time (based on `ActiveRecord::Base.default_timezone`).
      def get_time(value)
        get = ::ActiveRecord::Base.default_timezone == :utc ? :getutc : :getlocal
        value.respond_to?(get) ? value.send(get) : value
      end

      protected

      # @return whether the given SQL string is a 'SELECT' like query (returning a results)
      def self.select?(sql)
        JdbcConnection::select?(sql)
      end

      # @return whether the given SQL string is an 'INSERT' query
      def self.insert?(sql)
        JdbcConnection::insert?(sql)
      end

      # @return whether the given SQL string is an 'UPDATE' (or 'DELETE') like query
      def self.update?(sql)
        ! select?(sql) && ! insert?(sql)
      end

      unless defined? AbstractAdapter.type_cast_config_to_integer

        # @private
        def self.type_cast_config_to_integer(config)
          config =~ /\A\d+\z/ ? config.to_i : config
        end

      end

      # @private
      def self.type_cast_config_to_boolean(config)
        config == 'false' ? false : (config == 'true' ? true : config)
      end

      public

      # @note Used by Java API to convert dates from (custom) SELECTs (might get refactored).
      # @private
      def _string_to_date(value); jdbc_column_class.string_to_date(value) end

      # @note Used by Java API to convert times from (custom) SELECTs (might get refactored).
      # @private
      def _string_to_time(value); jdbc_column_class.string_to_dummy_time(value) end

      # @note Used by Java API to convert times from (custom) SELECTs (might get refactored).
      # @private
      def _string_to_timestamp(value); jdbc_column_class.string_to_time(value) end

      if ActiveRecord::VERSION::STRING > '4.2'

        # @private
        @@_date = nil

        # @private
        def _string_to_date(value)
          if jdbc_column_class.respond_to?(:string_to_date)
            jdbc_column_class.string_to_date(value)
          else
            (@@_date ||= ActiveRecord::Type::Date.new).send(:cast_value, value)
          end
        end

        # @private
        @@_time = nil

        # @private
        def _string_to_time(value)
          if jdbc_column_class.respond_to?(:string_to_dummy_time)
            jdbc_column_class.string_to_dummy_time(value)
          else
            (@@_time ||= ActiveRecord::Type::Time.new).send(:cast_value, value)
          end
        end

        # @private
        @@_date_time = nil

        # @private
        def _string_to_timestamp(value)
          if jdbc_column_class.respond_to?(:string_to_time)
            jdbc_column_class.string_to_time(value)
          else
            (@@_date_time ||= ActiveRecord::Type::DateTime.new).send(:cast_value, value)
          end
        end

      end

      if ActiveRecord::VERSION::MAJOR < 4 # emulating Rails 3.x compatibility
        JdbcConnection.raw_date_time = true if JdbcConnection.raw_date_time?.nil?
        JdbcConnection.raw_boolean = true if JdbcConnection.raw_boolean?.nil?
      elsif ArJdbc::AR42 # AR::Type should do the conversion - for better accuracy
        JdbcConnection.raw_date_time = true if JdbcConnection.raw_date_time?.nil?
        JdbcConnection.raw_boolean = true if JdbcConnection.raw_boolean?.nil?
      end

    end
  end
end
