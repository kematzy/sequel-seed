##
# Extension based upon Sequel::Migration and Sequel::Migrator
#
# Adds the Sequel::Seed and Sequel::Seeder classes, which allow
# the user to easily group entity changes and seed/fixture the database
# to a newer version only (unlike migrations, seeds are not directional).
#
# To load the extension:
#
#   Sequel.extension :seed
#
# It is also important to set the environment:
#
#   Sequel::Seed.environment = :development

module Sequel
  class Seed
    class << self
      attr_accessor :environment
    end

    def self.apply
      new.run
    end

    def self.descendants
      @descendants ||= []
    end

    def self.inherited(base)
      descendants << base
    end

    def run
    end
  end

  ##
  # Creates a Seed subclass according to the given +block+.
  #
  # The +env_labels+ lists on which environments the seed should be applicable.
  # If the current environment is not applicable, the seed is ignored. On the
  # other hand, if it is applicable, it will be listed in Seed.descendants and
  # subject to application (if it was not applied yet).
  #
  # Expected seed call:
  #
  #   Sequel.seed(:test) do # seed is only applicable to the test environment
  #     def run
  #       Entity.create attribute: value
  #     end
  #   end
  #
  # Wildcard seed:
  #
  #   Sequel.seed do # seed is applicable to every environment, or no environment
  #     def run
  #       Entity.create attribute: value
  #     end
  #   end
  #

  def self.seed *env_labels, &block
    return if env_labels.length > 0 && !env_labels.include?(Seed.environment)

    seed = Class.new(Seed)
    seed.class_eval(&block) if block_given?
    Seed.inherited(seed) unless Seed.descendants.include? seed
    seed
  end

  ##
  # Class resposible for applying all the seeds related to the current environment,
  # if and only if they were not previously applied.
  #
  # To apply the seeds/fixtures:
  #
  #   Sequel::Seeder.apply(db, directory)
  #
  # +db+ holds the Sequel database connection
  #
  # +directory+ the path to the seeds/fixtures files

  class Seeder
    SEED_FILE_PATTERN = /\A(\d+)_.+\.(rb|json|yml)\z/i.freeze
    SEED_SPLITTER = '_'.freeze
    MINIMUM_TIMESTAMP = 20000101

    class Error < Sequel::Error
    end

    class NotCurrentError < Error
    end

    def self.apply(db, directory, opts = {})
      seeder_class(directory).new(db, directory, opts).run
    end

    def self.seeder_class(directory)
      if self.equal?(Seeder)
        Dir.new(directory).each do |file|
          next unless SEED_FILE_PATTERN.match(file)
          return TimestampSeeder if file.split(SEED_SPLITTER, 2).first.to_i > MINIMUM_TIMESTAMP
        end
        raise(Error, 'seeder not available for files')
      else
        self
      end
    end

    attr_reader :column

    attr_reader :db

    attr_reader :directory

    attr_reader :ds

    attr_reader :files

    attr_reader :table

    def initialize(db, directory, opts = {})
      raise(Error, "Must supply a valid seed path") unless File.directory?(directory)
      @db = db
      @directory = directory
      @allow_missing_seed_files = opts[:allow_missing_seed_files]
      @files = get_seed_files
      schema, table = @db.send(:schema_and_table, opts[:table]  || self.class.const_get(:DEFAULT_SCHEMA_TABLE))
      @table = schema ? Sequel::SQL::QualifiedIdentifier.new(schema, table) : table
      @column = opts[:column] || self.class.const_get(:DEFAULT_SCHEMA_COLUMN)
      @ds = schema_dataset
      @use_transactions = opts[:use_transactions]
    end

    private

    def checked_transaction(seed, &block)
      use_trans = if @use_transactions.nil?
        @db.supports_transactional_ddl?
      else
        @use_transactions
      end

      if use_trans
        db.transaction(&block)
      else
        yield
      end
    end

    def remove_seed_classes
      Seed.descendants.each do |c|
        Object.send(:remove_const, c.to_s) rescue nil
      end
      Seed.descendants.clear
    end

    def seed_version_from_file(filename)
      filename.split(SEED_SPLITTER, 2).first.to_i
    end
  end

  ##
  # A Seeder subclass to apply timestamped seeds/fixtures files.
  # It follows the same syntax & semantics for the Seeder superclass.
  #
  # To apply the seeds/fixtures:
  #
  #   Sequel::TimestampSeeder.apply(db, directory)
  #
  # +db+ holds the Sequel database connection
  #
  # +directory+ the path to the seeds/fixtures files

  class TimestampSeeder < Seeder
    DEFAULT_SCHEMA_COLUMN = :filename
    DEFAULT_SCHEMA_TABLE = :schema_seeds

    Error = Seeder::Error

    attr_reader :applied_seeds

    attr_reader :seed_tuples

    def initialize(db, directory, opts = {})
      super
      @applied_seeds = get_applied_seeds
      @seed_tuples = get_seed_tuples
    end

    def run
      seed_tuples.each do |s, f|
        t = Time.now
        db.log_info("Begin applying seed #{f}")
        checked_transaction(s) do
          s.apply
          fi = f.downcase
          ds.insert(column => fi)
        end
        db.log_info("Finished applying seed #{f}, took #{sprintf('%0.6f', Time.now - t)} seconds")
      end
      nil
    end

    private

    def get_applied_seeds
      am = ds.select_order_map(column)
      missing_seed_files = am - files.map{|f| File.basename(f).downcase}
      if missing_seed_files.length > 0 && !@allow_missing_seed_files
        raise(Error, "Applied seed files not in file system: #{missing_seed_files.join(', ')}")
      end
      am
    end

    def get_seed_files
      files = []
      Dir.new(directory).each do |file|
        next unless SEED_FILE_PATTERN.match(file)
        files << File.join(directory, file)
      end
      files.sort_by{|f| SEED_FILE_PATTERN.match(File.basename(f))[1].to_i}
    end

    def get_seed_tuples
      remove_seed_classes
      seeds = []
      ms = Seed.descendants
      files.each do |path|
        f = File.basename(path)
        fi = f.downcase
        if !applied_seeds.include?(fi)
          load(path)
          el = [ms.last, f]
          if ms.last.present? && !seeds.include?(el)
            seeds << [ms.last, f]
          end
        end
      end
      seeds
    end

    def schema_dataset
      c = column
      ds = db.from(table)
      if !db.table_exists?(table)
        db.create_table(table){String c, :primary_key => true}
      elsif !ds.columns.include?(c)
        raise(Error, "Seeder table #{table} does not contain column #{c}")
      end
      ds
    end
  end
end
