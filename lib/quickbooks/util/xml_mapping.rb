require 'nokogiri'
require 'bigdecimal'
require 'date'
require 'time'
require 'active_support'
# The same core extensions ROXML used to load; models rely on them (e.g. HashWithIndifferentAccess)
require 'active_support/inflector'
require 'active_support/core_ext/object/duplicable'
require 'active_support/core_ext/module/delegation'
require 'active_support/core_ext/array/extract_options'
require 'active_support/core_ext/hash'
require 'active_support/core_ext/string/starts_ends_with'
require 'active_support/core_ext/object/blank'

module Quickbooks
  module Util
    # Declarative XML <-> object mapping built on Nokogiri.
    #
    # Implements the subset of the ROXML DSL used by the models:
    #
    #   xml_name 'Invoice'
    #   xml_convention :camelcase
    #   xml_accessor :id,        :from => 'Id'
    #   xml_accessor :name,      :from => '@name'          # attribute
    #   xml_accessor :value,     :from => :content         # text content of the node itself
    #   xml_accessor :total,     :from => 'TotalAmt', :as => BigDecimal, :to_xml => Proc.new { |v| v.to_f }
    #   xml_accessor :lines,     :from => 'Line', :as => [Line]
    #   xml_reader   :prefs,     :from => 'OtherPrefs/NameValue', :as => { :key => 'Name', :value => 'Value' }
    #   xml_reader   :fields,    :from => 'CustomField', :as => [CustomField], :in => 'CustomField'
    module XmlMapping
      def self.included(base)
        base.extend(ClassMethods)
      end

      CASTS = {
        Integer    => ->(v) { v.to_i },
        Float      => ->(v) { Float(v) },
        BigDecimal => ->(v) { BigDecimal(v) },
        Date       => ->(v) { Date.parse(v) },
        DateTime   => ->(v) { DateTime.parse(v) },
        Time       => ->(v) { Time.parse(v) },
        :bool      => lambda do |v|
          case v.downcase
          when 'true', 'yes', '1', 't' then true
          when 'false', 'no', '0', 'f' then false
          end
        end
      }.freeze

      def self.node_from(data)
        case data
        when Nokogiri::XML::Document then data.root
        when Nokogiri::XML::Node then data
        else Nokogiri::XML(data.respond_to?(:read) ? data.read : data.to_s).root
        end
      end

      class Attribute
        attr_reader :accessor, :attr_name, :sought_type, :cast_type, :wrapper

        def initialize(accessor, opts = {}, &block)
          opts.assert_valid_keys(:from, :as, :in, :to_xml)
          @accessor = accessor.to_s
          @attr_name = @accessor.chomp('?')
          @wrapper = opts[:in]
          @to_xml = opts[:to_xml]
          @block = block

          as = opts[:as] || default_type
          @collection = as.is_a?(Array)
          as = as.first if @collection

          if as.is_a?(Hash)
            as.assert_valid_keys(:key, :value)
            @hash = as
            @sought_type = :hash
          elsif mapped?(as)
            @sought_type = as
          else
            raise ArgumentError, "Invalid :as argument #{as}" unless as.nil? || as == :text || CASTS.key?(as)
            @sought_type = :text
            @cast_type = as unless as == :text
          end

          from = opts[:from]
          from ||= @sought_type.xml_tag_name if mapped?(@sought_type)
          @kind =
            if from == :content then :content
            elsif from.to_s.start_with?('@') then :attribute
            else :element
            end
          from = from.to_s.sub('@', '') if @kind == :attribute
          @explicit_name = from.is_a?(String)
          @raw_name = (from || (collection? || hash? ? @attr_name.singularize : @attr_name)).to_s
          @names = {}
        end

        def collection?
          @collection
        end

        def hash?
          @sought_type == :hash
        end

        def mapped?(type = @sought_type)
          type.is_a?(Class) && type.respond_to?(:from_xml)
        end

        def instance_variable_name
          :"@#{attr_name}"
        end

        def setter
          :"#{attr_name}="
        end

        def default
          if collection? then []
          elsif hash? then {}
          end
        end

        # Element/attribute name, after applying the naming convention of +klass+
        def name(klass)
          @names[klass] ||= @explicit_name ? @raw_name : conventionize(klass, @raw_name)
        end

        def read(node, klass)
          value =
            case @kind
            when :content then node.content.to_s.presence
            when :attribute then read_attribute(node, klass)
            else read_elements(node, klass)
            end
          value = default if value.nil?
          value = transform(value)
          hash? ? to_hash(value) : value
        end

        def write(parent, instance)
          value = instance.public_send(accessor)
          value = @to_xml.call(value) if @to_xml.respond_to?(:call)
          return if value.nil?

          parent = find_or_create(parent, @wrapper) if @wrapper && parent.name != @wrapper
          case @kind
          when :content then parent.content = value.to_s
          when :attribute then parent[name(instance.class)] = value.to_s
          else write_elements(parent, name(instance.class), value)
          end
        end

        private

        def default_type
          if accessor.end_with?('?') then :bool
          elsif accessor.end_with?('_on') then Date
          elsif accessor.end_with?('_at') then DateTime
          end
        end

        def conventionize(klass, what)
          convention = klass.respond_to?(:xml_naming_convention) && klass.xml_naming_convention
          convention ? convention.call(what) : what
        end

        def read_attribute(node, klass)
          nodes = @wrapper ? children_at(node, @wrapper) : [node]
          nodes.first && nodes.first[name(klass)]
        end

        def read_elements(node, klass)
          path = [@wrapper, name(klass)].compact.join('/')
          nodes = children_at(node, path)
          if nodes.empty? && collection? && !@wrapper
            nodes = children_at(node, "#{conventionize(klass, @raw_name.pluralize)}/#{name(klass)}")
          end
          return nil if nodes.empty?

          values = nodes.map { |n| read_node(n) }
          collection? || hash? ? values : values.first
        end

        def read_node(node)
          if hash?
            [text_at(node, @hash[:key]), text_at(node, @hash[:value])]
          elsif mapped?
            @sought_type.from_xml(node)
          else
            node.content
          end
        end

        def text_at(node, path)
          found = children_at(node, path.to_s).first
          found && found.content
        end

        # Child elements matching a slash-separated path of local names
        def children_at(node, path)
          path.split('/').inject([node]) do |nodes, segment|
            nodes.flat_map { |n| n.element_children.select { |c| c.name == segment } }
          end
        end

        def transform(value)
          value = cast(value) if @cast_type
          @block ? @block.call(value) : value
        rescue StandardError => ex
          raise ex, "#{accessor}: #{ex.message}"
        end

        def cast(value)
          caster = CASTS.fetch(@cast_type)
          return value.map { |v| v.blank? ? nil : caster.call(v) } if value.is_a?(Array)
          value.blank? ? nil : caster.call(value)
        end

        def to_hash(pairs)
          grouped = pairs.each_with_object({}) { |(k, v), h| (h[k] ||= []) << v }
          grouped.transform_values { |v| v.size == 1 ? v.first : v }
        end

        def write_elements(parent, name, value)
          *wraps, leaf = name.split('/')
          unless wraps.empty?
            return if value.respond_to?(:empty?) && value.empty?
            parent = find_or_create(parent, wraps.join('/'))
          end

          if hash?
            value.each_pair do |k, v|
              node = add_node(parent, leaf)
              add_node(node, @hash[:key].to_s).content = k.to_s
              add_node(node, @hash[:value].to_s).content = v.to_s
            end
          elsif mapped?
            Array(collection? ? value : [value]).each do |v|
              if v.is_a?(XmlMapping) || collection?
                # Models may override #to_xml to return a String; Nokogiri parses it as a fragment
                parent.add_child(v.to_xml(:name => leaf))
              else
                add_node(parent, leaf).content = v.to_xml
              end
            end
          else
            (collection? ? value : [value]).each { |v| add_node(parent, leaf).content = v.to_s }
          end
        end

        def find_or_create(node, path)
          path.split('/').inject(node) do |n, segment|
            n.element_children.find { |c| c.name == segment } || add_node(n, segment)
          end
        end

        def add_node(parent, name)
          parent.add_child(Nokogiri::XML::Node.new(name, parent.document))
        end
      end

      module ClassMethods
        def xml_name(name)
          @xml_tag_name = name
        end

        def xml_convention(convention)
          @xml_naming_convention = convention.to_proc
        end

        def xml_tag_name
          if defined?(@xml_tag_name)
            @xml_tag_name
          elsif superclass.respond_to?(:xml_tag_name)
            superclass.xml_tag_name
          end
        end

        def xml_naming_convention
          if defined?(@xml_naming_convention)
            @xml_naming_convention
          elsif superclass.respond_to?(:xml_naming_convention)
            superclass.xml_naming_convention
          end
        end

        def tag_name
          return xml_tag_name if xml_tag_name
          tag = name.to_s.split('::').last.to_s
          xml_naming_convention ? xml_naming_convention.call(tag.underscore) : tag.downcase
        end

        # Own attributes first, then inherited ones
        def xml_attributes
          @xml_attributes ||= []
          inherited = superclass.respond_to?(:xml_attributes) ? superclass.xml_attributes : []
          (@xml_attributes + inherited).freeze
        end

        def xml_reader(*syms, &block)
          xml_attr(*syms, &block).each { |attr| define_xml_reader(attr) }
        end

        def xml_accessor(*syms, &block)
          xml_attr(*syms, &block).each do |attr|
            define_xml_reader(attr)
            attr_writer(attr.attr_name)
          end
        end

        def from_xml(data, *initialization_args)
          node = XmlMapping.node_from(data)
          new(*initialization_args).tap do |instance|
            xml_attributes.each do |attr|
              value = attr.read(node, self)
              if instance.respond_to?(attr.setter)
                instance.public_send(attr.setter, value)
              else
                instance.instance_variable_set(attr.instance_variable_name, value)
              end
            end
          end
        rescue ArgumentError => e
          raise e, e.message + " for class #{self}"
        end

        private

        def xml_attr(*syms, &block)
          opts = syms.last.is_a?(Hash) ? syms.pop : {}
          syms.map do |sym|
            Attribute.new(sym, opts, &block).tap do |attr|
              if xml_attributes.map(&:accessor).include?(attr.accessor)
                raise "Accessor #{attr.accessor} is already defined as XML accessor in class #{name}"
              end
              @xml_attributes << attr
            end
          end
        end

        def define_xml_reader(attr)
          define_method(attr.accessor) do
            unless instance_variable_defined?(attr.instance_variable_name)
              instance_variable_set(attr.instance_variable_name, attr.default)
            end
            instance_variable_get(attr.instance_variable_name)
          end
        end
      end

      def to_xml(params = {})
        root = Nokogiri::XML::Node.new(params[:name] || self.class.tag_name, Nokogiri::XML::Document.new)
        self.class.xml_attributes.each { |attr| attr.write(root, self) }
        root
      end
    end
  end
end
