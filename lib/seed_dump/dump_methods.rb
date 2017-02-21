class SeedDump
  module DumpMethods
    include Enumeration

    def dump(records, options = {})
      return nil if records.count == 0

      io = open_io(options)

      write_records_to_io(records, io, options)

      ensure
        io.close if io.present?
    end

    private

    def dump_record(record, options)
      attribute_strings = []

      # We select only string attribute names to avoid conflict
      # with the composite_primary_keys gem (it returns composite
      # primary key attribute names as hashes).
      if record.class.to_s == "Settings"
        attribute_strings << 
          if record.value.class == String 
            "#{record.var}: '#{record.value}' "
          elsif record.value.class == Hash 
            "#{record.var}: #{record.value.map { |k, v| [k, (v.kind_of?(Array) ? v : v.to_s)] }.to_h}"
          else
            "#{record.var}: #{record.value}"
          end
      else
        attributes = record.attributes
        attributes.merge!({"remote_data_url" => "#{options.fetch(:root_url,'')}#{record.data.url}"}) if attributes.has_key?("data")
        attributes.select {|key| key.is_a?(String) }.each do |attribute, value|
          attribute_strings << dump_attribute_new(attribute, value, options) unless options[:exclude].include?(attribute.to_sym)
        end
      end
      


      open_character, close_character = options[:import] ? ['[', ']'] : ['{', '}']

      "#{open_character}#{attribute_strings.join(", ")}#{close_character}"
    end

    def dump_attribute_new(attribute, value, options)
      options[:import] ? value_to_s(value) : "#{attribute}: #{value_to_s(value)}"
    end

    def value_to_s(value)
      value = case value
              when BigDecimal, IPAddr
                value.to_s
              when Date, Time, DateTime
                value.to_s(:db)
              when Range
                range_to_string(value)
              else
                value
              end

      value.inspect
    end

    def range_to_string(object)
      from = object.begin.respond_to?(:infinite?) && object.begin.infinite? ? '' : object.begin
      to   = object.end.respond_to?(:infinite?) && object.end.infinite? ? '' : object.end
      "[#{from},#{to}#{object.exclude_end? ? ')' : ']'}"
    end

    def open_io(options)
      if options[:file].present?
        mode = options[:append] ? 'a+' : 'w+'

        File.open(options[:file], mode)
      else
        StringIO.new('', 'w+')
      end
    end

    def write_records_to_io(records, io, options)
      options[:exclude] ||= [:id, :created_at, :updated_at]

      if model_for(records).to_s == "PublicActivity::Activity"
        io.write("\nPublicActivity::Activity.unscoped.destroy_all\n\n")
      end

      method = options[:import] ? 'import' : 'create!'
      if options[:import]
        io.write("[#{attribute_names(records, options).map {|name| name.to_sym.inspect}.join(', ')}], ")
      end
      io.write("# #{model_for(records)} data:\n[ ")

      enumeration_method = if records.is_a?(ActiveRecord::Relation) || records.is_a?(Class)
                             :active_record_enumeration
                           else
                             :enumerable_enumeration
                           end

      send(enumeration_method, records, io, options) do |record_strings, last_batch|
        io.write(record_strings.join(",\n  "))

        io.write(",\n  ") unless last_batch
      end

      if model_for(records).to_s == "User"
        io.write("\n].each {|u|\n user = User.new(u)\n user.skip_confirmation_notification!\n user.update_attribute(:encrypted_password, u.fetch(:encrypted_password))\n}\n\n")
      elsif model_for(records).to_s == "Settings"
        io.write("\n].reduce({}, :merge).each {|k,v| Settings.create(var: k, value: v)}\n\n")
      elsif ["Communication", "Permission", "Notification", "CriterionAnswer"].include?(model_for(records).to_s)
        io.write("\n].each {|a| \nbegin\n  #{model_for(records)}.create(a)\n rescue\n nil\nend }\n\n")
      elsif ["Mailboxer::Conversation", "Mailboxer::Notification", "Mailboxer::Receipt"].include?(model_for(records).to_s)
        io.write("\n].each {|a| \n  #{model_for(records)}.new(a).save(validate: false) }\n\n")
      else
        io.write("\n].each {|a| #{model_for(records)}.create(a)}\n\n")
      end

      if options[:file].present?
        nil
      else
        io.rewind
        io.read
      end
    end

    def attribute_names(records, options)
      attribute_names = if records.is_a?(ActiveRecord::Relation) || records.is_a?(Class)
                          records.attribute_names
                        else
                          records[0].attribute_names
                        end

      attribute_names.select {|name| !options[:exclude].include?(name.to_sym)}
    end

    def model_for(records, var = false)
      x = if records.is_a?(Class)
          records
        elsif records.respond_to?(:model)
          records.model
        else
          records[0].class
        end
      return x unless var
      return x.to_s.pluralize.downcase
    end

  end
end
