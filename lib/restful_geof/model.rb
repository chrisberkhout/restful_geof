require "pg"
require "pg_typecast"
require "json"
require "restful_geof/query"

module RestfulGeof

  class Table

    def initialize(database, table_name)
      @database = database
      @table_name = table_name
      options = { dbname: @database }
      options[:host] = ENV["RESTFUL_GEOF_PG_HOST"] || "localhost"
      options[:port] = ENV["RESTFUL_GEOF_PG_PORT"] || "5432"
      options[:user] = ENV["RESTFUL_GEOF_PG_USERNAME"] if ENV["RESTFUL_GEOF_PG_USERNAME"]
      options[:password] = ENV["RESTFUL_GEOF_PG_PASSWORD"] if ENV["RESTFUL_GEOF_PG_PASSWORD"]
      @connection = PG.connect(options)
    end

    attr_reader :database, :table_name, :connection

    def geometry_column
      @geometry_column = column_info.map { |r| r[:column_name] if r[:udt_name] == "geometry" }.compact.first
    end

    def tsvector_columns
      @tsvector_column = column_info.map { |r| r[:column_name] if r[:udt_name] == "tsvector" }.compact
    end

    def normal_columns
      @normal_columns = column_info.map { |r| r[:column_name] } - ([geometry_column] + tsvector_columns)
    end

    def column_info
      @column_info ||= begin
        @connection.exec(
          Query.new.
            select("column_name", "udt_name").
            from("information_schema.columns").
            where("table_catalog = '#{ esc_s @database }'").
            and("table_name = '#{ esc_s @table_name }'").to_sql
        ).to_a
      end
    end

    private

    def esc_i identifier
      @connection.escape_identifier(identifier)
    end

    def esc_s string
      @connection.escape_string(string)
    end

  end

  class Model

    def initialize(database, table_name)
      @table = Table.new(database, table_name)
      @database = @table.database
      @table_name = @table.table_name
      @connection = @table.connection
    end


    def create
    end

    def read
    end

    def find(conditions={})
      conditions[:is] ||= {}
      conditions[:contains] ||= {}
      conditions[:matches] ||= {}

      where_conditions = (
        conditions[:is].map do |field, value|
          col_type = @table.column_info.select { |r| r[:column_name] == field }.first[:udt_name]
          if %w{integer int smallint bigint int2 int4 int8}.include?(col_type)
            value_expression = Integer(value).to_s
          else
            value_expression = "'#{ @connection.escape_string value }'"
          end
          "#{ @connection.escape_string field } = #{ value_expression }"
        end +
        conditions[:contains].map do |field, value|
          "#{ @connection.escape_string field }::varchar ILIKE '%#{ @connection.escape_string value.gsub(/(?=[%_])/, "\\") }%'"
        end +
        conditions[:matches].map do |field, value|
          safe_value = @connection.escape_string value
          <<-END_CONDITION
            #{ @connection.escape_string field } @@
            CASE
              WHEN char_length(plainto_tsquery('#{ safe_value }')::varchar) > 0
              THEN to_tsquery(plainto_tsquery('#{ safe_value }')::varchar || ':*')
              ELSE plainto_tsquery('#{ safe_value }')
            END
          END_CONDITION
        end
      ).join(" AND ")

      sql = <<-END_SQL
        SELECT
          #{@table.normal_columns.join(", ")}
          #{ ", ST_AsGeoJSON(ST_Transform(#{@table.geometry_column}, 4326), 15, 2) AS geometry_geojson" if @table.geometry_column }
        FROM #{@connection.escape_string @table_name}
        #{ "WHERE #{where_conditions}" unless where_conditions.empty? }
        #{
          unless conditions[:contains].empty?
            "ORDER BY " +
            conditions[:contains].map do |field, value|
              "position(upper('#{ @connection.escape_string value }') in upper(#{ @connection.escape_string field }::varchar))"
            end.join(", ")
          end
        }
        #{ "LIMIT #{conditions[:limit]}" if conditions[:limit] }
        ;
      END_SQL

      as_feature_collection(@connection.exec(sql).to_a)
    end

    def update
    end

    def delete
    end

    private

    def as_feature_collection(results)
      {
        "type" => "FeatureCollection",
        "features" => results.to_a.map do |row|
          {
            "type" => "Feature",
            "properties" => row.select { |k,v| k != :geometry_geojson }
          }.merge(
            begin
              if row[:geometry_geojson].to_s.empty?
                {}
              else
                { "geometry" => JSON.parse(row[:geometry_geojson]) }
              end
            end
          )
        end
      }.to_json
    end

  end
end
