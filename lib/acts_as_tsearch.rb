require 'active_record'
require 'postgres_extensions'

module TsearchMixin
  module Acts #:nodoc:
    module Tsearch #:nodoc:

      def self.included(mod)
        mod.extend(ClassMethods)
      end

      # declare the class level helper methods which
      # will load the relevant instance methods
      # defined below when invoked
      module ClassMethods
        
        # Extends the calling class with PostgreSQL full text search methods.
        def acts_as_tsearch(options = {})
          return false unless database_table_exists?
          ensure_database_supports_text_search!
          extract_tsearch_config_from_options!(options)
          
          class_eval do
            after_save :update_vector_row      
            extend TsearchMixin::Acts::Tsearch::SingletonMethods
          end
          
          include TsearchMixin::Acts::Tsearch::InstanceMethods
        end
        
        
        private
        
        
        # Raises an exception unless running on PostgreSQL with full text search built in.
        def ensure_database_supports_text_search!
          postgresql_version = connection.instance_variable_get('@postgresql_version')  
          raise "acts_as_tsearch: you must upgrade to Postgres 8.3 before using tsearch" unless postgresql_version >= 80300   
        end
        
        # Extracts tsearch configuration from the given options Hash.
        # Raises an exception if options is nil or malformed.
        def extract_tsearch_config_from_options!(options)
          if !options.is_a?(Hash)
            raise "Missing required fields for acts_as_tsearch.  At a bare minimum you need :fields => 'SomeFileName'.  Please see
            documentation on http://acts-as-tsearch.rubyforge.org"
          end
          
          fields = []
          tsearch_config = {}
          default_config = { :auto_update_index => true }
          
          #they passed in :fields => "somefield" or :fields => [:one, :two, :three]
          #:fields => "somefield"
          if options[:fields].is_a?(String)
            tsearch_config = {:vectors => default_config.clone}
            tsearch_config[:vectors][:fields] = 
              {"a" => {:columns => [options[:fields]], :weight => 1.0}}
            fields << options[:fields]
          
          #:fields => [:one, :two]
          elsif options[:fields].is_a?(Array)
            tsearch_config = {:vectors => default_config.clone}
            tsearch_config[:vectors][:fields] = 
              {"a" => {:columns => options[:fields], :weight => 1.0}}
            fields = options[:fields]
         
          # :fields => {"a" => {:columns => [:one, :two], :weight => 1},
          #              "b" => {:colums => [:three, :four], :weight => 0.5}
          #              }
          elsif options[:fields].is_a?(Hash)
            tsearch_config = {:vectors => default_config.clone}
            tsearch_config[:vectors][:fields] = options[:fields]
            options[:fields].keys.each do |k|
              options[:fields][k][:columns].each do |f|
                fields << f
              end
            end
          else
            # :vectors => {
            #   :auto_update_index => false,
            #   :fields => [:title, :description]
            # }
            options.keys.each do |k|
              tsearch_config[k] = default_config.clone
              tsearch_config[k].update(options[k])
              if options[k][:fields].is_a?(String)
                fields << options[k][:fields]
              elsif options[k][:fields].is_a?(Array)
                options[k][:fields].each do |f|
                  fields << f
                end
              else
                options[k][:fields].keys.each do |kk|
                  options[k][:fields][kk][:columns].each do |f|
                    fields << f
                  end
                end
              end
              #TODO: add error checking here for complex fields - right know - assume it's correct
              #puts k.to_s + " yamled = " + tsearch_config.to_yaml
            end
            
          end
          
          validate_option_fields!(fields)
          
          # Define tsearch_config as a class inheritable attribute, so that
          # subclasses inherit it and can optionally override it.
          write_inheritable_attribute :tsearch_config, tsearch_config
          class_inheritable_reader :tsearch_config
        end #tsearch_config_from_options
        
        
        # Raises an exception unless all columns in +fields+ exist within database table.
        def validate_option_fields!(fields)
          fields.uniq!
          #check to make sure all fields exist
          #TODO Write check code for multi-table... ignoring this for now
          missing_fields = []
          fields.each do |f|
            missing_fields << f.to_s unless column_names().include?(f.to_s) or f.to_s.include?(".")
          end
          raise ArgumentError, "Missing fields: #{missing_fields.sort.join(",")} in acts_as_tsearch definition for 
            table #{table_name}" if missing_fields.size > 0
        end
        
        
        # Returns a boolean answering whether the database table exists.
        def database_table_exists?
          begin
            column_names()
            return true
          rescue Exception => e
            logger.error "acts_as_tsearch: Table #{table_name()} for Model #{human_name()} could not be accessed. Is the database configured?"
            return false
          end
        end

      end #ClassMethods

      module SingletonMethods

        #Find options for a tsearch2 formated query
        #TODO:  Not sure how to handle order... current we add to it if it exists but this might not
        #be the right thing to do
        def find_by_tsearch_options(search_string, options = {}, tsearch_options = {})
          raise ActiveRecord::RecordNotFound, "Couldn't find #{name} without a search string" if search_string.blank?
          
          options = deep_copy(options || {})
          tsearch_options = deep_copy(tsearch_options || {})
          set_default_tsearch_options!(tsearch_options)

          ensure_tsearch_vector_column_exists!(tsearch_options)
          check_for_vector_column(tsearch_options[:vector])

          search_string = fix_tsearch_query(search_string, tsearch_options)

          rank_function = tsearch_rank_function(tsearch_options)
          add_tsearch_rank_to_select!(options, rank_function)
          add_tsearch_rank_to_order!(options, rank_function)

          add_tsearch_headlines_to_select!(options, tsearch_options)
          add_tsearch_query_string_to_from!(options, search_string)
          add_tsearch_vector_to_conditions!(options, tsearch_options, search_string)
          
          options
        end

        def find_by_tsearch(search_string, options = {}, tsearch_options = {})
          options = find_by_tsearch_options(search_string, options, tsearch_options)
          find(:all, options)
          #   :select => "#{table_name}.*, ts_rank_cd(blogger_groups.vectors, query) as tsearch_rank",
          #   :from => "#{table_name}, to_tsquery('default','#{search_string}') as query",
          #   :conditions => "#{table_name}.vectors @@ query",
          #   :order => "tsearch_rank"

        end

        def scoped_by_tsearch(search_string, options = {}, tsearch_options = {})
          options = find_by_tsearch_options(search_string, options, tsearch_options)
          scoped(options)
        end

        def count_by_tsearch(search_string, options = {}, tsearch_options = {})
          options = find_by_tsearch_options(search_string, options, tsearch_options)
          options[:select] = "count(*)"
          options[:order] = "1 desc"
          find(:all,options)[0][:count].to_i
        end        
        
        # Create a tsearch_query from a Google like query (and or " +)
        def fix_tsearch_query(query, tsearch_options = {})
          if (tsearch_options[:fix_query].nil? || tsearch_options[:fix_query] == true)
            terms = query_to_terms(clean_query(query))
            terms.flatten!
            terms.shift
            terms.join
          else
            query
          end
        end
        
        # Convert a search query into an array of terms [prefix, term] where
        # Prefix is | or & (tsearch and/or) and term is a phrase (with or with negation)
        def query_to_terms(query)
          query.scan(/(\+|or \-?|and \-?|\-)?("[^"]*"?|[\w\-]+)/).collect do |prefix, term|
            term = "(#{term.scan(/[\w']+/).join('&')})" if term[0,1] == '"'
            term = "!#{term}" if prefix =~ /\-/
            [(prefix =~ /or/) ? '|' : '&', term] 
          end
        end
        
        def clean_query(query)
          query.gsub(/[^\w\-\+'"]+/, " ").gsub("'", "''").strip.downcase     
        end
        
        #checks to see if vector column exists.  if it doesn't exist, create it and update isn't index.
        def check_for_vector_column(vector_name = "vectors")
          #check for the basics
          if !column_names().include?(vector_name)
            #puts "Creating vector column"
            create_vector(vector_name)
            #puts "Update vector index"
            update_vector(nil,vector_name)
            # raise "Table is missing column [vectors].  Run method create_vector and then 
            # update_vector to create this column and populate it."
          end
        end

        #current just falls through if it fails... this needs work
        def create_vector(vector_name = "vectors")
          sql = []
          if column_names().include?(vector_name)
            sql << "alter table #{table_name} drop column #{vector_name}"
          end
          sql << "alter table #{table_name} add column #{vector_name} tsvector"
          sql << "CREATE INDEX #{table_name}_fts_#{vector_name}_index ON #{table_name} USING gist(#{vector_name})"
          sql.each do |s|
            begin
              connection.execute(s)
              #puts s
              reset_column_information
            rescue StandardError => bang
              puts "Error in create_vector executing #{s} " + bang.to_yaml
              puts ""
            end
          end
        end

        def remove_vector(vector_name = 'vectors')
          sql = []
          if column_names().include?(vector_name)
            sql << "ALTER TABLE #{table_name} DROP COLUMN #{vector_name}"
          end
          sql.each do |s|
            begin
              connection.execute(s)
              #puts s
              reset_column_information
            rescue StandardError => bang
              puts "Error in remove_vector executing #{s} " + bang.to_yaml
              puts ""
            end
          end
        end

        def update_vectors(row_id = nil)
          tsearch_config.keys.each do |k|
            update_vector(row_id, k.to_s)
          end
        end
        
        #This will update the vector colum for all rows (unless a row_id is passed).  If you think your indexes are screwed
        #up try running this.  This get's called by the callback after_update when you change your model.
        # Sample SQL
        #   update 
        # 	  blog_entries
        #   set 
        # 	  vectors = to_tsvector('default',
        #   coalesce(blog_entries.title,'') || ' ' || coalesce(blog_comments.comment,'')
        #   )
        #   from
        # 	  blog_entries b2 left outer join blog_comments on b2.id = blog_comments.blog_entry_id
        #   where b2.id = blog_entries.id
        #
        # Sample call
        #   BlogEntry.acts_as_tsearch :vectors => {
        #           :fields => {
        #               "a" => {:columns => ["blog_entry.title"], :weight => 1},
        #               "b" => {:columns => ["blog_comments.comment"], :weight => 0.5}
        #             },
        #           :tables => {
        #               :blog_comments => {
        #                 :from => "blog_entries b2 left outer join blog_comments on blog_comments.blog_entry_id = b2.id",
        #                 :where => "b2.id = blog_entries.id"
        #                 }
        #             }
        #           }
        def update_vector(row_id = nil, vector_name = "vectors")
          sql = ""
          if !column_names().include?(vector_name)
            create_vector(vector_name)
          end
          if !tsearch_config[vector_name.intern]
            raise "Missing vector #{vector_name} in hash #{tsearch_config.to_yaml}"
          else
            fields = tsearch_config[vector_name.intern][:fields]
            tables = tsearch_config[vector_name.intern][:tables]
            if fields.is_a?(Array)
              sql = "update #{table_name} set #{vector_name} = to_tsvector(#{coalesce_array(fields)})"
            elsif fields.is_a?(String)
              sql = "update #{table_name} set #{vector_name} = to_tsvector(#{fields})"
            elsif fields.is_a?(Hash)
              if fields.size > 4
                raise "acts_as_tsearch currently only supports up to 4 weighted sets."
              else
                setweights = []
                ["a","b","c","d"].each do |f|
                  if fields[f]
                    setweights << "setweight( to_tsvector(#{coalesce_array(fields[f][:columns])}),'#{f.upcase}')"
                  end
                end
                sql = "update #{table_name} set #{vector_name} = #{setweights.join(" || ")}"
              end
            else
              raise ":fields was not an Array, Hash or a String."
            end
            from_arr = []
            where_arr = []
            if !tables.nil? and tables.is_a?(Hash)
              tables.keys.each do |k|
                from_arr << tables[k][:from]
                where_arr << tables[k][:where]
              end
              if from_arr.size > 0
                sql << " from " + from_arr.join(", ")
              end
            end
            if !row_id.nil?
              where_arr << "#{table_name}.id = #{row_id}"
            end
            if where_arr.size > 0
              sql << " where " + where_arr.join(" and ")
            end
            
            connection.execute(sql)
            #puts sql
          end #tsearch config test
        end
                
        def coalesce_array(arr)
          res = []
          arr.each do |f|
            res << "coalesce(#{f},'')"
          end
          return res.join(" || ' ' || ")        
        end
        
          # Returns a SQL Select string for full text search rank function.
          # Helpful when combining text search queries with other kinds of queries.
          def tsearch_rank_select_sql(tsearch_options = {})
            rank_function = tsearch_rank_function(tsearch_options)
            options = {}
            add_tsearch_rank_to_select!(options, rank_function)
            options[:select]
          end
          
          # Returns a string of SQL to include in the call to ts_rank_cd().
          # Returns a blank string if search config does not have the key [:vectors][:fields].
          # Backfills unspecified weights for each field with the PostgreSQL defaults {0.1, 0.2, 0.4, 1.0}.
          # See http://www.postgresql.org/docs/8.3/static/textsearch-controls.html#TEXTSEARCH-RANKING.
          def tsearch_weights_sql
            return '' unless (f =  tsearch_config[:vectors] && tsearch_config[:vectors][:fields] ) && f.is_a?(Hash)
            weights = [
              ( f["d"] && f["d"][:weight] ) || 0.1,
              ( f["c"] && f["c"][:weight] ) || 0.2,
              ( f["b"] && f["b"][:weight] ) || 0.4,
              ( f["a"] && f["a"][:weight] ) || 1.0
            ]
            "'{ #{weights.join(", ") } }', " 
          end

        
        private
        
          def set_default_tsearch_options!(tsearch_options)
            tsearch_options[:vector] ||= 'vectors'
          end
        ### Query formatting helpers
        
        # Raises an exception if table doesn't include a text search vector column
        def ensure_tsearch_vector_column_exists!(tsearch_options)
          unless tsearch_config.keys.include?(tsearch_options[:vector].intern)
            raise "Vector [#{tsearch_options[:vector].intern}] not found in acts_as_tsearch config: #{tsearch_config.to_yaml}" 
          end
        end
        
        def add_tsearch_rank_to_select!(options, tsearch_rank_function)
          select_part = "#{tsearch_rank_function} as tsearch_rank"
          if options[:select]
            if options[:select].downcase != "count(*)"
              options[:select] << ", #{select_part}"
            end
          else
            options[:select] = "#{table_name}.*, #{select_part}"
          end
        end    
        
        def add_tsearch_rank_to_order!(options, tsearch_rank_function)
          order_part = "tsearch_rank desc"
          if !options[:order]
            # Note if the :include option to ActiveRecord::Base.find is used, the :select option is ignored
            # (in ActiveRecord::Associations.construct_finder_sql_with_included_associations),
            # so the 'tsearch_rank' function def above doesn't make it into the generated SQL, and the order
            # by tsearch_rank fails. So we have to provide that function here, in the order_by clause.
            options[:order] = (options.has_key?(:include) ? tsearch_rank_function + "desc" : order_part)
          end
        end
        
        def add_tsearch_headlines_to_select!(options, tsearch_options)
          if tsearch_options[:headlines]
            tsearch_options[:headlines].each do |h|
              options[:select] << ", ts_headline(#{table_name}.#{h},tsearch_query) as #{h}_headline"
            end
          end
        end
        
        def add_tsearch_query_string_to_from!(options, search_string)     
          from_part = "to_tsquery('#{search_string}') as tsearch_query"
          if options[:from]
            options[:from] = "#{from_part}, #{options[:from]}"
          else
            options[:from] = "#{from_part}, #{table_name}"
          end
        end
        
        def add_tsearch_vector_to_conditions!(options, tsearch_options, search_string)
          where_part = "#{table_name}.#{tsearch_options[:vector]} @@ tsearch_query"
          options[:conditions] = merge_conditions(options[:conditions], where_part)
        end

        # Returns SQL string for text search rank function
        def tsearch_rank_function(tsearch_options = {})
          vector_column = tsearch_options[:vector] || 'vectors'
          "ts_rank_cd(#{ tsearch_weights_sql } #{table_name}.#{vector_column}, tsearch_query#{','+tsearch_options[:normalization].to_s if tsearch_options[:normalization]})"
        end

        def deep_copy(object)
          Marshal.load( Marshal.dump(object))
        end
      end
      
      # Adds instance methods.
      module InstanceMethods
        
        def update_vector_row
          self.class.tsearch_config.keys.each do |k|
            if self.class.tsearch_config[k][:auto_update_index] == true
              self.class.update_vector(self.id,k.to_s)
            end
          end
        end
        
      end

    end
  end
end

# reopen ActiveRecord and include all the above to make
# them available to all our models if they want it

ActiveRecord::Base.class_eval do
  include TsearchMixin::Acts::Tsearch
end
