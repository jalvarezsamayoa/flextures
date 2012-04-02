# encoding: utf-8

require 'ostruct'
require 'csv'

require 'flextures/flextures_base_config'
require 'flextures/flextures_extension_modules'
require 'flextures/flextures'
require 'flextures/flextures_factory'

module Flextures
  # Dumperと違ってデータの吐き出し処理をまとめたクラス
  module Loader 
    PARENT = Flextures

    # 型に応じて勝手にdefault値を設定する
    COMPLETER = {
      binary:->{ 0 },
      boolean:->{ false },
      date:->{ DateTime.now },
      datetime:->{ DateTime.now },
      decimal:->{ 0 },
      float:->{ 0.0 },
      integer:->{ 0 },
      string:->{ "" },
      text:->{ "" },
      time:->{ DateTime.now },
      timestamp:->{ DateTime.now },
    }

    # 型の変換を行う
    TRANSLATER = {
      binary:->(d){ d.to_i },
      boolean:->(d){ (0==d || ""==d || !d) ? false : true },
      date:->(d){ Date.parse(d.to_s) },
      datetime:->(d){ DateTime.parse(d.to_s) },
      decimal:->(d){ d.to_i },
      float:->(d){ d.to_f },
      integer:->(d){ d.to_i },
      string:->(d){ d.to_s },
      text:->(d){ d.to_s },
      time:->(d){ DateTime.parse(d.to_s) },
      timestamp:->(d){ DateTime.parse(d.to_s) },
    }

    # csv 優先で存在している fixtures をロード
    def self.load format
      file_name = format[:file] || format[:table]
      dir_name = format[:dir] || LOAD_DIR
      method = nil
      method = :csv if File.exist? "#{dir_name}#{file_name}.csv"
      method = :yml if File.exist? "#{dir_name}#{file_name}.yml"
      self::send(method, format) if method
    end

    # fixturesをまとめてロード、主にテストtest/unit, rspec で使用する
    #
    # 全テーブルが対象
    # fixtures :all
    # テーブル名で一覧する
    # fixtures :users, :items
    # ハッシュで指定
    # fixtures :users => :users2
    def self.flextures *fixtures
      # :allですべてのfixtureを反映
      fixtures = ActiveRecord::Base.connection.tables if fixtures.size== 1 and :all == fixtures.first
      fixtures_hash = fixtures.pop if fixtures.last and fixtures.last.is_a? Hash # ハッシュ取り出し
      fixtures.each{ |table_name| Loader::load table: table_name }
      fixtures_hash.each{ |k,v| Loader::load table: k, file: v } if fixtures_hash
      fixtures
    end

    # CSVのデータをロードする
    def self.csv format
      table_name = format[:table].to_s
      file_name = format[:file] || table_name
      dir_name = format[:dir] || LOAD_DIR
      inpfile = "#{dir_name}#{file_name}.csv"
      klass = PARENT::create_model table_name
      attributes = klass.columns.map &:name
      filter = create_filter klass, Factory[table_name]
      klass.delete_all
      CSV.open( inpfile ) do |csv|
        keys = csv.shift # keyの設定
        warning "CSV", attributes, keys
        csv.each do |values|
          h = values.extend(Extensions::Array).to_hash(keys)
          args = [h, file_name]
          o = filter.call *args[0,filter.arity]
          o.save
        end
      end
    end

    # YAML形式でデータをロードする
    def self.yml format
      table_name = format[:table].to_s
      file_name = format[:file] || table_name
      dir_name = format[:dir] || LOAD_DIR
      inpfile = "#{dir_name}#{file_name}.yml"
      klass = PARENT::create_model table_name
      attributes = klass.columns.map &:name
      filter = create_filter klass, Factory[table_name]
      klass.delete_all
      YAML.load(File.open(inpfile)).each do |k,h|
        warning "YAML", attributes, h.keys
        args = [h, file_name]
        o = filter.call *args[0,filter.arity]
        o.save
      end
    end

    # 欠けたカラムを検知してメッセージを出しておく
    def self.warning format, attributes, keys
      (attributes-keys).each { |name| print "Warning: #{format} colum is missing! [#{name}]\n" }
      (keys-attributes).each { |name| print "Warning: #{format} colum is left over! [#{name}]\n" }
    end

    # フィクスチャから取り出した値を、加工して欲しいデータにするフィルタを作成して返す
    def self.create_filter klass, factory=nil
      columns = klass.columns
      # テーブルからカラム情報を取り出し
      column_hash = {}
      columns.each { |col| column_hash[col.name] = col }
      # 自動補完が必要なはずのカラム
      lack_columns = columns.select { |c| !c.null and !c.default }.map{ |o| o.name.to_sym }
      not_nullable_columns = columns.select { |c| !c.null }.map &:name
      # ハッシュを受け取って、必要な値に加工してからハッシュで返すラムダを返す
      return->(h){
        # テーブルに存在しないキーが定義されているときは削除
        h.select! { |k,v| column_hash[k] }
        o = klass.new 
        # 値がnilでないなら型をDBで適切なものに変更
        h.each{ |k,v| nil==v || o[k] = TRANSLATER[column_hash[k].type].call(v) }
        not_nullable_columns.each{ |k| o[k]==nil && o[k] = TRANSLATER[column_hash[k].type].call(k) }
        # FactoryFilterを動作させる
        factory.call(o) if factory
        # 値がnilの列にデフォルト値を補間
        lack_columns.each { |k| nil==o[k] && o[k] = COMPLETER[column_hash[k].type].call }
        o
      }
    end
  end
end
