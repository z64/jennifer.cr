require "../relation/base"
require "../relation/*"
require "../model/errors"

require "./resource"
require "./mapping"
require "./sti_mapping"
require "./validation"
require "./callback"
require "./parameter_converter"
require "./converters"

module Jennifer
  module Model
    abstract class Base < Resource
      module AbstractClassMethods
        # Returns if primary field is autoincrementable
        abstract def primary_auto_incrementable?

        # Converts String based hash to `Hash(String, Jennifer::DBAny)`
        #
        # NOTE: Deprecated - will be removed in 0.7.0. Please, use https://github.com/imdrasil/form_object instead
        abstract def build_params(hash)
      end

      extend AbstractClassMethods
      include Mapping
      include STIMapping
      include Validation
      include Callback

      @@table_name : String?
      @@foreign_key_name : String?
      @@actual_table_field_count : Int32?
      @@has_table : Bool?

      # Returns whether model has a table.
      def self.has_table?
        @@has_table = adapter.table_exists?(table_name).as(Bool) if @@has_table.nil?
        @@has_table
      end

      # Represent actual amount of model's table column amount (is grepped from db).
      def self.actual_table_field_count
        @@actual_table_field_count ||= adapter.table_column_count(table_name)
      end

      # Sets custom table name.
      def self.table_name(value : String | Symbol)
        @@table_name = value.to_s
        @@actual_table_field_count = nil
        @@has_table = nil
      end

      # Returns table name.
      def self.table_name : String
        @@table_name ||=
          begin
            name = ""
            class_name = Inflector.demodulize(to_s)
            name = self.table_prefix if self.responds_to?(:table_prefix)
            Inflector.pluralize(name + class_name.underscore)
          end
      end

      # Sets custom model foreign key name.
      def self.foreign_key_name(value : String | Symbol)
        @@foreign_key_name = value.to_s
        @@foreign_key_name = nil
      end

      # Returns model foreign key name.
      def self.foreign_key_name
        @@foreign_key_name ||= Inflector.singularize(table_name) + "_id"
      end

      # Returns default model parameter converter.
      def self.parameter_converter
        @@converter ||= ParameterConverter.new
      end

      # Initializes new object based on given arguments.
      #
      # `after_initialize` callbacks are invoked. If model mapping allows creating an object
      # without passing any argument - relevant `#build` method will be generated for such model.
      def self.build(values : Hash | NamedTuple, new_record : Bool)
        o = new(values, new_record)
        o.__after_initialize_callback
        o
      end

      # Returns if record isn't persisted
      def new_record?
        @new_record
      end

      # Returns if record isn't deleted.
      def destroyed?
        @destroyed
      end

      def self.create(values : Hash | NamedTuple)
        o = build(values)
        o.save
        o
      end

      def self.create
        o = build({} of String => DBAny)
        o.save
        o
      end

      def self.create(**opts)
        o = build(**opts)
        o.save
        o
      end

      def self.create!(values : Hash | NamedTuple)
        o = build(values)
        o.save!
        o
      end

      def self.create!
        o = build({} of Symbol => DBAny)
        o.save!
        o
      end

      def self.create!(**opts)
        o = build(**opts)
        o.save!
        o
      end

      private abstract def save_record_under_transaction(skip_validation)
      private abstract def init_attributes(values : Hash)
      private abstract def init_attributes(values : DB::ResultSet)
      private abstract def __refresh_changes
      private abstract def __refresh_relation_retrieves

      # Sets *name* field with *value*
      abstract def set_attribute(name, value)

      # Sets given *values* to proper fields and stores them directly to db without
      # any validation or callback
      abstract def update_columns(values)

      # Returns if any field was changed. If field again got first value - `true` anyway
      # will be returned.
      abstract def changed? : Bool

      # Returns field by given name. If object has no such field - will raise `BaseException`.
      #
      # To avoid raising exception set `raise_exception` to `false`.
      abstract def attribute(name : String, raise_exception : Bool)

      # Deletes object from db and calls callbacks
      abstract def destroy : Bool

      # Returns named tuple of all fields should be saved (because they are changed).
      abstract def arguments_to_save

      # Returns named tuple of all model fields to insert.
      abstract def arguments_to_insert

      # Returns list of available model classes.
      def self.models
        {% begin %}
          {% if !@type.all_subclasses.empty? %}
            [
              {% for model in @type.all_subclasses %}
                {{model.id}},
              {% end %}
            ]
          {% else %}
            [] of ::Jennifer::Model::Base.class
          {% end %}
        {% end %}
      end

      def self.build(pull : DB::ResultSet)
        {% begin %}
          {% klasses = @type.all_subclasses.select { |s| s.constant("STI") == true } %}
          {% if !klasses.empty? %}
            hash = adapter.result_to_hash(pull)
            o =
              case hash["type"]
              when "", nil, "{{@type}}"
                new(hash, false)
              {% for klass in klasses %}
              when "{{klass}}"
                {{klass}}.new(hash, false)
              {% end %}
              else
                raise ::Jennifer::UnknownSTIType.new(self, hash["type"])
              end
          {% else %}
            o = new(pull)
          {% end %}

          o.__after_initialize_callback
          o
        {% end %}
      end

      def attribute(name : Symbol, raise_exception : Bool = true)
        attribute(name.to_s, raise_exception)
      end

      def update(hash : Hash | NamedTuple)
        update_attributes(hash)
        save
      end

      def update(**opts)
        update(opts)
      end

      def update!(hash : Hash | NamedTuple)
        update_attributes(hash)
        save!
      end

      def update!(**opts)
        update!(opts)
      end

      def update_attributes(hash : Hash | NamedTuple)
        hash.each { |k, v| set_attribute(k, v) }
      end

      def update_attributes(**opts)
        update_attributes(opts)
      end

      # Sets *value* to field with name *name* and stores them directly to db without
      # any validation or callback
      def update_column(name, value : Jennifer::DBAny)
        update_columns({name => value})
      end

      def save!(skip_validation : Bool = false)
        raise Jennifer::RecordInvalid.new(errors.to_a) unless save(skip_validation)
        true
      end

      def save(skip_validation : Bool = false) : Bool
        unless self.class.adapter.under_transaction?
          self.class.transaction do
            save_record_under_transaction(skip_validation)
          end || false
        else
          save_record_under_transaction(skip_validation)
        end
      end

      # Saves all changes to db without invoking transaction; if validation not passed - returns `false`
      def save_without_transaction(skip_validation : Bool = false) : Bool
        return false unless skip_validation || validate!
        return false unless __before_save_callback
        response = new_record? ? store_record : update_record
        __after_save_callback
        response
      end

      # Perform destroy without starting a transaction
      def destroy_without_transaction
        return false if new_record? || !__before_destroy_callback
        if delete
          @destroyed = true
          __after_destroy_callback
        end
        @destroyed
      end

      # Deletes object from DB without calling callbacks.
      def delete
        return if new_record? || errors.any?
        this = self
        self.class.all.where { this.class.primary == this.primary }.delete
      end

      # Lock current object in DB.
      def lock!(type : String | Bool = true)
        this = self
        self.class.all.where { this.class.primary == this.primary }.lock(type).to_a
      end

      # Starts transaction and locks current object.
      def with_lock(type : String | Bool = true)
        self.class.transaction do |t|
          self.lock!(type)
          yield(t)
        end
      end

      private def update_record : Bool
        return false unless __before_update_callback
        return true unless changed?
        res = self.class.adapter.update(self)
        __after_update_callback
        res.rows_affected == 1
      end

      private def store_record : Bool
        return false unless __before_create_callback
        res = self.class.adapter.insert(self)
        init_primary_field(res.last_insert_id.as(Int)) if primary.nil? && res.last_insert_id > -1
        raise ::Jennifer::BaseException.new("Record hasn't been stored to the db") if res.rows_affected == 0
        @new_record = false
        __after_create_callback
        true
      end

      # Reloads all fields from db.
      def reload
        raise ::Jennifer::RecordNotFound.new("It is not persisted yet") if new_record?
        this = self
        self.class.all.where { this.class.primary == this.primary }.limit(1).each_result_set do |rs|
          init_attributes(rs)
        end
        __refresh_changes
        __refresh_relation_retrieves
        self
      end

      # Performs table lock for current model's table.
      def self.with_table_lock(type : String | Symbol, &block)
        adapter.with_table_lock(table_name, type.to_s) { |t| yield t }
      end

      def self.find(id)
        _id = id
        this = self
        all.where { this.primary == _id }.first
      end

      def self.find!(id)
        _id = id
        this = self
        all.where { this.primary == _id }.first!
      end

      def self.destroy(*ids)
        destroy(ids.to_a)
      end

      def self.destroy(ids : Array)
        _ids = ids
        all.where do
          if _ids.size == 1
            c(primary_field_name) == _ids[0]
          else
            c(primary_field_name).in(_ids)
          end
        end.destroy
      end

      def self.delete(*ids)
        delete(ids.to_a)
      end

      def self.delete(ids : Array)
        _ids = ids
        all.where do
          if _ids.size == 1
            c(primary_field_name) == _ids[0]
          else
            c(primary_field_name).in(_ids)
          end
        end.delete
      end

      def self.import(collection : Array(self))
        adapter.bulk_insert(collection)
      end

      macro inherited
        ::Jennifer::Model::Validation.inherited_hook
        ::Jennifer::Model::Callback.inherited_hook
        ::Jennifer::Model::RelationDefinition.inherited_hook

        after_save :__refresh_changes

        # :nodoc:
        def self.superclass
          {{@type.superclass}}
        end

        macro finished
          ::Jennifer::Model::Validation.finished_hook
          ::Jennifer::Model::Callback.finished_hook

          # :nodoc:
          def self.relation(name : String)
            RELATIONS[name]
          rescue e : KeyError
            super(name)
          end
        end
      end
    end
  end
end
