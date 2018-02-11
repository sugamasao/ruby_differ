require "ruby_differ/version"
require 'sqlite3'

module RubyDiffer
  class NotFoundRubyVersion < StandardError;end
  class StragePath
    attr_reader :path
    def initialize(path)
      @path = path || File.join(__dir__, '..', 'database.sqlite3')
    end
  end
  class Save
    def self.run(strage_path)
      strage = Strage.new(strage_path.path)
      version = strage.register_version(RUBY_VERSION)
      classes = ObjectSpace.each_object(Class).select{|c| !c.name.to_s.empty? }.sort_by {|c| c.name }
      classes.each do |c|
        # プログラム上の依存関係は除外
        next if 'SQLite3' == c.name || c.name.start_with?('Bundler')
        class_name = strage.register_class(c.name, version['id'])
        strage.register_methods(c.instance_methods(false), Strage::METHOD_TYPE_INSTANCE, version['id'], class_name['id'])
        strage.register_methods(c.methods(false), Strage::METHOD_TYPE_CLASS, version['id'], class_name['id'])
      end
      strage.close
    end
    def self.diff(old, new, strage_path)
      strage = Strage.new(strage_path.path)
      if old.nil? || new.nil?
        puts "list of Versions."
        strage.all_versions.each do |v|
          puts v['name']
        end
        exit
      end
      begin
        old_version = StrageVersion.new(strage.find_version(old))
        old_classes = StrageClass.new(strage.find_classes(old_version.id))

        new_version = StrageVersion.new(strage.find_version(new))
        new_classes = StrageClass.new(strage.find_classes(new_version.id))
      rescue NotFoundRubyVersion => e
        warn "#{e.message} #{old} or #{new}"
        exit
      end

      puts "*" * 20
      puts "Class"
      puts "*" * 20
      unless old_classes.classes == new_classes.classes
        (old_classes.classes - new_classes.classes).each do |name|
          puts "#{ old_version.name } -> #{ new_version.name } Deleted Class => #{name}"
        end
        (new_classes.classes - old_classes.classes).each do |name|
          puts "#{ old_version.name } -> #{ new_version.name } Added Class => #{name}"
        end
      end

      puts "*" * 20
      puts "Instance Methods"
      puts "*" * 20
      (old_classes.classes & new_classes.classes).each do |class_name|
        old_methods = strage.find_methods(Strage::METHOD_TYPE_INSTANCE, old_version.id, old_classes.class_id(class_name)).map{|m| m['name']}
        new_methods = strage.find_methods(Strage::METHOD_TYPE_INSTANCE, new_version.id, new_classes.class_id(class_name)).map{|m| m['name']}

        (old_methods - new_methods).each do |name|
          puts "#{ old_version.name } -> #{ new_version.name } Deleted Instance Method => #{ class_name }##{ name }"
        end
        (new_methods - old_methods).each do |name|
          puts "#{ old_version.name } -> #{ new_version.name } Added Instance Method => #{ class_name }##{ name}"
        end
      end

      puts "*" * 20
      puts "Class Methods"
      puts "*" * 20
      (old_classes.classes & new_classes.classes).each do |class_name|
        old_methods = strage.find_methods(Strage::METHOD_TYPE_CLASS, old_version.id, old_classes.class_id(class_name)).map{|m| m['name']}
        new_methods = strage.find_methods(Strage::METHOD_TYPE_CLASS, new_version.id, new_classes.class_id(class_name)).map{|m| m['name']}

        (old_methods - new_methods).each do |name|
          puts "#{ old_version.name } -> #{ new_version.name } Deleted Class Method => #{ class_name }.#{ name }"
        end
        (new_methods - old_methods).each do |name|
          puts "#{ old_version.name } -> #{ new_version.name } Added Class Method => #{ class_name }.#{ name}"
        end
      end

    end
  end

  class StrageVersion
    attr_reader :id, :name
    def initialize(data)
      data = data.first
      raise NotFoundRubyVersion if data.nil?
      @id = data['id']
      @name = data['name']
    end
  end
  class StrageClass
    attr_reader :id, :name
    def initialize(data)
      @data = data
    end

    def class_id(name)
      @data.find {|c| c['name'] == name}['id']
    end

    def classes
      @data.map{|c| c['name']}
    end
  end
  class Strage
    METHOD_TYPE_INSTANCE = 0
    METHOD_TYPE_CLASS = 1
    def initialize(path)
      path = Pathname(path)
      path.dirname.mkpath
      @db = SQLite3::Database.new(path.to_s)
      @db.results_as_hash = true

      sql = <<-SQL
      CREATE TABLE IF NOT EXISTS ruby_classes(
        id INTEGER PRIMARY KEY,
        ruby_versions_id INTEGER,
        name TEXT
      );
      SQL
      @db.execute(sql)
      sql = <<-SQL
      CREATE TABLE IF NOT EXISTS ruby_versions(
        id INTEGER PRIMARY KEY,
        name TEXT
      );
      SQL
      @db.execute(sql)
      sql = <<-SQL
      CREATE TABLE IF NOT EXISTS ruby_methods(
        id INTEGER PRIMARY KEY,
        ruby_versions_id INTEGER,
        ruby_classes_id INTEGER,
        name TEXT,
        method_type INTEGER
      );
      SQL
      @db.execute(sql)
      sql = <<-SQL
      CREATE UNIQUE INDEX IF NOT EXISTS version on ruby_versions(name);
      SQL
      @db.execute(sql)
      sql = <<-SQL
      CREATE UNIQUE INDEX IF NOT EXISTS class on ruby_classes(name, ruby_versions_id);
      SQL
      @db.execute(sql)
      sql = <<-SQL
      CREATE UNIQUE INDEX IF NOT EXISTS methodn on ruby_methods(ruby_versions_id, ruby_classes_id, name, method_type);
      SQL
      @db.execute(sql)
    end

    def register_version(version)
      puts "Save Ruby Version = #{ version }"
      result = find_version(version)
      if result.empty?
        @db.execute('INSERT INTO ruby_versions(name) VALUES(?)', version)
        result = find_version(version)
      end
      result.first
    end

    def register_class(name, version_id)
      result =  find_class(name, version_id)
      if result.empty?
        @db.execute('INSERT INTO ruby_classes(name, ruby_versions_id) VALUES(?, ?)', name, version_id)
        result =  find_class(name, version_id)
      end
      result.first
    end

    def register_methods(class_methods, method_type, version_id, class_id)
      class_methods.each do |name|
        name = name.to_s
        result = find_method(name, method_type, version_id, class_id)
        if result.empty?
          @db.execute('INSERT INTO ruby_methods(name, method_type, ruby_versions_id, ruby_classes_id) VALUES(?, ?, ?, ?)', name, method_type, version_id, class_id)
        end
      end
    end

    def all_versions
      @db.execute('SELECT name FROM ruby_versions')
    end

    def find_version(version)
      @db.execute('SELECT * FROM ruby_versions WHERE name = (?) limit 1', version)
    end

    def find_class(name, version_id)
      @db.execute('SELECT * FROM ruby_classes WHERE name = (?) and ruby_versions_id = (?) limit 1', name, version_id)
    end

    def find_classes(version_id)
      @db.execute('SELECT id, name FROM ruby_classes WHERE ruby_versions_id = (?)', version_id)
    end

    def find_method(name, method_type, version_id, class_id)
      @db.execute('SELECT * FROM ruby_methods WHERE name = (?) and method_type = (?) and ruby_versions_id = (?) and ruby_classes_id = (?) limit 1', name, method_type, version_id, class_id)
    end

    def find_methods(method_type, version_id, class_id)
      @db.execute('SELECT name FROM ruby_methods WHERE method_type = (?) and ruby_versions_id = (?) and ruby_classes_id = (?)', method_type, version_id, class_id)
    end

    def close
      @db.close
    end
  end
end
