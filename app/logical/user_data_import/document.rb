# frozen_string_literal: true

class UserDataImport
  # Parses and validates an uploaded user data backup (format version 1, as written by
  # UserDataExport on e621ng-based sites):
  #
  #   {
  #     "format_version": 1,
  #     "exported_at": "2026-11-09T02:30:00Z",
  #     "profile": { "about": "", "artinfo": "", "avatar": { "post_id": 1, "cropped": false } | null },
  #     "favorites": { "<post id>": "<favorited at>" },
  #     "sets": { "<set id>": { "name", "short_name", "description", "created_at", "updated_at",
  #                             "is_public", "transfer_on_delete", "post_ids": [..] } }
  #   }
  #
  # The file is untrusted. Any structural problem or exceeded limit rejects the whole file;
  # nothing is coerced. Validation needs no database access and runs twice: on upload, and
  # again in the job on the stored copy (.from_storage).
  #
  # jsonb doesn't keep object key order, so the favorites' order in the file is captured here
  # as "favorite_order" (an array) and stored alongside. It breaks ties between favorites with
  # the same timestamp, which are then spread out by a microsecond each (see #spread_ties).
  class Document
    class Invalid < StandardError
      attr_reader :errors

      def initialize(errors)
        @errors = errors
        super(errors.join("; "))
      end
    end

    FORMAT_VERSION = 1
    MAX_FILE_SIZE = 32.megabytes
    # root -> sets -> set -> post_ids is the deepest legitimate path.
    MAX_NESTING = 4
    # Backups come from e6ai: the last post there, and the posts it destroyed, which a
    # genuine backup can't reference.
    MAX_POST_ID = 193_896
    DESTROYED_POST_IDS = Set[
      1, 2, 14_046, 14_055, 19_805, 19_992, 20_049, 40_002, 40_003, 40_004, 40_005, 40_012, 40_016, 40_017, 40_024,
      92_114, 92_371, 92_372, 103_873, 104_003, 104_171, 104_336, 104_571, 104_795, 115_207, 115_416, 115_561,
      115_590, 115_699, 115_852, 115_900, 122_182, 142_887, 142_888, 143_202, 143_532, 143_866, 143_867, 143_898,
      143_988, 144_225, 144_468, 144_501, 144_550, 144_596, 144_609, 144_610, 145_879, 147_072, 147_140, 147_489,
      147_597, 148_032, 148_205, 149_963, 150_831, 153_875, 153_997, 155_452, 155_453, 155_773, 158_744, 158_940,
      163_892, 163_893, 164_021, 164_022
    ].freeze
    MAX_SET_ID = 2_147_483_647
    MAX_TIMESTAMP_LENGTH = 40
    # e6ai's first post.
    EARLIEST_TIME = Time.utc(2022, 10, 17)
    CLOCK_SKEW = 1.day
    MAX_ERRORS = 20

    ID_KEY = /\A[1-9]\d{0,9}\z/
    TIMESTAMP = /\A\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(?:\.\d{1,6})?(?:Z|[+-]\d\d:\d\d)\z/
    # Mirrors PostSet's shortname validations. PostSet stores short names downcased, so an
    # uppercase letter means the file was edited.
    SHORT_NAME_CHARS = /\A[a-z0-9_]+\z/
    SHORT_NAME_LETTER = /\A\d*[a-z_][a-z0-9_]*\z/
    # Control characters other than tab, line feed and carriage return (C0, DEL and C1).
    CONTROL_CHARS = /[\u0000-\u0008\u000B\u000C\u000E-\u001F\u007F-\u009F]/
    INVALID_FILE = "This is not a valid backup file"

    ROOT_KEYS = %w[format_version exported_at profile favorites sets].freeze
    PROFILE_KEYS = %w[about artinfo avatar].freeze
    AVATAR_KEYS = %w[post_id cropped].freeze
    SET_KEYS = %w[name short_name description created_at updated_at is_public transfer_on_delete post_ids].freeze

    # file_index is the entry's position in the file; it only breaks timestamp ties.
    FavoriteEntry = Struct.new(:post_id, :favorited_at, :file_index)
    BackupSet = Struct.new(:source_id, :name, :short_name, :description, :created_at, :updated_at,
                           :is_public, :transfer_on_delete, :post_ids) do
      # Identifies the same source set across separate imports of the same backup.
      def map_key
        "#{source_id}:#{created_at.utc.iso8601}"
      end
    end

    # The raised favorite limit (User#favorite_limit), the most any account can hold.
    def self.max_favorites = Danbooru.config.default_favorite_limit * 2
    def self.max_sets = PostSet::MAX_SETS_PER_USER
    def self.max_posts_per_set = Danbooru.config.post_set_post_limit.to_i
    # +1 for the avatar.
    def self.max_total_post_refs = max_favorites + (max_sets * max_posts_per_set) + 1
    def self.max_profile_text = Danbooru.config.user_about_max_size
    def self.max_set_description = Danbooru.config.pool_descr_max_size

    # Parses raw upload bytes. Raises Invalid.
    def self.parse(raw)
      raise Invalid, ["The file is larger than the #{MAX_FILE_SIZE / 1.megabyte} MB limit"] if raw.bytesize > MAX_FILE_SIZE

      text = raw.dup.force_encoding(Encoding::UTF_8)
      raise Invalid, ["The file isn't valid UTF-8 text"] unless text.valid_encoding?

      data = begin
        JSON.parse(text, max_nesting: MAX_NESTING, allow_duplicate_key: false)
      rescue JSON::ParserError # includes JSON::NestingError
        raise Invalid, [INVALID_FILE]
      end

      favorite_order = data.is_a?(Hash) && data["favorites"].is_a?(Hash) ? data["favorites"].keys : []
      new(data, favorite_order)
    end

    # Rebuilds a document from its stored form and validates it again.
    def self.from_storage(stored)
      raise Invalid, ["The stored backup is missing"] unless stored.is_a?(Hash)

      data = stored.except("favorite_order")
      new(data, stored["favorite_order"])
    end

    attr_reader :exported_at, :profile, :favorites, :sets

    def initialize(data, favorite_order)
      @errors = []
      @data = data
      validate!(favorite_order)
      raise Invalid, @errors if @errors.any?
    end

    def to_storage
      @data.merge("favorite_order" => @favorite_order)
    end

    # Every distinct post id referenced anywhere in the backup.
    def referenced_post_ids
      ids = favorites.map(&:post_id)
      sets.each { |set| ids.concat(set.post_ids) }
      ids << profile[:avatar][:post_id] if profile[:avatar]
      ids.uniq
    end

    def empty?
      favorites.empty? && sets.empty? && profile[:about].empty? && profile[:artinfo].empty? && profile[:avatar].nil?
    end

    private

    def validate!(favorite_order)
      return error("The file must contain a JSON object") unless @data.is_a?(Hash)
      return unless keys_exact?(@data, ROOT_KEYS, "the file")

      version = @data["format_version"]
      unless version.is_a?(Integer) && version == FORMAT_VERSION
        return error("format_version #{version.inspect} isn't supported (expected #{FORMAT_VERSION})")
      end

      @exported_at = timestamp(@data["exported_at"], "exported_at", latest: Time.current + CLOCK_SKEW)
      # Every later timestamp is checked against exported_at.
      return if @errors.any?

      validate_profile(@data["profile"])
      validate_favorites(@data["favorites"], favorite_order)
      validate_sets(@data["sets"])
      validate_total if @errors.empty?
    end

    def validate_profile(profile)
      return error("profile must be an object") unless profile.is_a?(Hash)
      return unless keys_exact?(profile, PROFILE_KEYS, "profile")

      about = text(profile["about"], "profile.about", max: self.class.max_profile_text)
      artinfo = text(profile["artinfo"], "profile.artinfo", max: self.class.max_profile_text)
      avatar = nil
      unless profile["avatar"].nil?
        raw = profile["avatar"]
        if !raw.is_a?(Hash)
          error("profile.avatar must be an object or null")
        elsif keys_exact?(raw, AVATAR_KEYS, "profile.avatar")
          post_id = post_id(raw["post_id"], "profile.avatar.post_id")
          cropped = boolean(raw["cropped"], "profile.avatar.cropped")
          avatar = { post_id: post_id, cropped: cropped }
        end
      end
      @profile = { about: about, artinfo: artinfo, avatar: avatar }
    end

    def validate_favorites(favorites, favorite_order)
      @favorites = []
      return error("favorites must be an object") unless favorites.is_a?(Hash)
      if favorites.size > self.class.max_favorites
        return error("favorites: #{favorites.size} favorites, the maximum is #{self.class.max_favorites}")
      end

      order = Array(favorite_order)
      unless favorite_order.is_a?(Array) && order.size == favorites.size && order.all?(String) && order.uniq.size == order.size && order.all? { |key| favorites.key?(key) }
        return error("The favorites' order record doesn't match the favorites")
      end
      @favorite_order = order

      file_index = order.each_with_index.to_h
      favorites.each do |key, value|
        break if @errors.size >= MAX_ERRORS
        next error("favorites: #{key.inspect} isn't a valid post ID") unless post_id_key?(key)

        time = timestamp(value, "favorites.#{key}")
        @favorites << FavoriteEntry.new(key.to_i, time, file_index[key]) if time
      end
      @favorites.sort_by! { |fav| [fav.favorited_at, fav.file_index] }
      spread_ties
    end

    # The export has whole seconds, so favorites made in the same second share a timestamp.
    # Each one after the first is moved a microsecond past the one before it, in file order,
    # so lists ordered by created_at show them in their original order. Deterministic, so a
    # resumed run computes the same times.
    def spread_ties
      previous = nil
      @favorites.each do |fav|
        fav.favorited_at = previous + Rational(1, 1_000_000) if previous && fav.favorited_at <= previous
        previous = fav.favorited_at
      end
    end

    def validate_sets(sets)
      @sets = []
      return error("sets must be an object") unless sets.is_a?(Hash)
      return error("sets: #{sets.size} sets, the maximum is #{self.class.max_sets}") if sets.size > self.class.max_sets

      sets.each do |key, set|
        break if @errors.size >= MAX_ERRORS
        path = "sets.#{key}"
        next error("sets: #{key.inspect} isn't a valid set ID") unless key.match?(ID_KEY) && key.to_i <= MAX_SET_ID
        next error("#{path} must be an object") unless set.is_a?(Hash)
        next unless keys_exact?(set, SET_KEYS, path)

        backup_set = validate_set(key.to_i, set, path)
        @sets << backup_set if backup_set
      end
      @sets.sort_by!(&:source_id)
    end

    def validate_set(source_id, set, path)
      errors_before = @errors.size
      name = text(set["name"], "#{path}.name", min: 3, max: 100)
      short_name = text(set["short_name"], "#{path}.short_name", min: 3, max: 50)
      if short_name && !valid_short_name?(short_name)
        error("#{path}.short_name #{short_name.inspect} isn't a valid set short name")
      end
      description = text(set["description"], "#{path}.description", max: self.class.max_set_description)
      created_at = timestamp(set["created_at"], "#{path}.created_at")
      updated_at = timestamp(set["updated_at"], "#{path}.updated_at")
      is_public = boolean(set["is_public"], "#{path}.is_public")
      transfer_on_delete = boolean(set["transfer_on_delete"], "#{path}.transfer_on_delete")
      post_ids = post_set_id_list(set["post_ids"], "#{path}.post_ids")
      return nil if @errors.size > errors_before

      BackupSet.new(source_id, name, short_name, description, created_at, updated_at, is_public, transfer_on_delete, post_ids)
    end

    def post_set_id_list(value, path)
      return error("#{path} must be an array") unless value.is_a?(Array)
      if value.size > self.class.max_posts_per_set
        return error("#{path}: #{value.size} posts, the maximum is #{self.class.max_posts_per_set}")
      end

      bad = value.index { |id| !valid_post_id?(id) }
      return error("#{path}[#{bad}]: #{value[bad].inspect} isn't a valid post ID") if bad
      return error("#{path} lists the same post more than once") if value.uniq.size != value.size

      value
    end

    def validate_total
      total = @favorites.size + @sets.sum { |set| set.post_ids.size } + (@profile[:avatar] ? 1 : 0)
      return if total <= self.class.max_total_post_refs

      error("The backup references #{total} posts in total, the maximum is #{self.class.max_total_post_refs}")
    end

    def keys_exact?(hash, expected, path)
      missing = expected - hash.keys
      unknown = hash.keys - expected
      error("#{path} is missing #{missing.join(', ')}") if missing.any?
      error("#{path} has unexpected keys: #{unknown.first(5).join(', ')}") if unknown.any?
      missing.empty? && unknown.empty?
    end

    def text(value, path, max:, min: 0)
      return error("#{path} must be a string") unless value.is_a?(String)
      return error("#{path} contains a control character") if value.match?(CONTROL_CHARS)
      return error("#{path} is #{value.length} characters, the maximum is #{max}") if value.length > max
      return error("#{path} is #{value.length} characters, the minimum is #{min}") if value.length < min

      value
    end

    def boolean(value, path)
      return error("#{path} must be true or false") unless [true, false].include?(value)

      value
    end

    def post_id(value, path)
      return error("#{path}: #{value.inspect} isn't a valid post ID") unless valid_post_id?(value)

      value
    end

    def valid_short_name?(value)
      value.match?(SHORT_NAME_CHARS) && value.match?(SHORT_NAME_LETTER)
    end

    def valid_post_id?(value)
      value.is_a?(Integer) && value.between?(1, MAX_POST_ID) && DESTROYED_POST_IDS.exclude?(value)
    end

    def post_id_key?(key)
      key.match?(ID_KEY) && valid_post_id?(key.to_i)
    end

    # exported_at itself passes `latest`; everything else is checked after it was set.
    def timestamp(value, path, latest: @exported_at + CLOCK_SKEW)
      unless value.is_a?(String) && value.length <= MAX_TIMESTAMP_LENGTH && value.match?(TIMESTAMP)
        return error("#{path}: #{value.inspect.truncate(60)} isn't an ISO 8601 timestamp with a time zone")
      end

      time = Time.iso8601(value).utc
      return error("#{path}: #{value} is outside the allowed range") unless time.between?(EARLIEST_TIME, latest)

      time
    rescue ArgumentError
      error("#{path}: #{value.inspect.truncate(60)} isn't a valid timestamp")
    end

    def error(message)
      @errors << message if @errors.size < MAX_ERRORS
      nil
    end
  end
end
