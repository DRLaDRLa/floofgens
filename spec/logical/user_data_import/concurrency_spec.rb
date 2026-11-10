# frozen_string_literal: true

require "rails_helper"

# Runs an import batch and a normal favorite operation on two real database connections at the
# same time, to check that they wait on each other instead of deadlocking and that the counters
# stay exact. This needs committed data, so it doesn't use a test transaction; it creates only
# rows it can delete afterwards (posts via insert_all, the import row) and uses the seeded admin.
RSpec.describe UserDataImport::Runner, "#favorites_batch" do
  self.use_transactional_tests = false

  let(:admin) { User.find_by!(name: "admin") }
  let(:post_ids) { [902_001, 902_002, 902_003] }
  let(:time) { "2026-03-01T10:00:00.000000Z" }

  let!(:original_favorite_count) { admin.user_status.favorite_count }
  let!(:import) do
    # Built, not saved: saving would commit tags and versions this spec couldn't clean up.
    template = FactoryBot.build(:post, uploader: admin).attributes.except("id", "change_seq", "created_at", "updated_at")
                         .merge("source" => "")
    Post.insert_all!(post_ids.map { |id| template.merge("id" => id, "md5" => SecureRandom.hex(16)) })
    create_import(admin, parse_backup(favorites: post_ids.index_with { "2026-03-01T10:00:00Z" }), sets: false)
  end
  let!(:token) { UserDataImport.claim!(import.id) }

  after do
    Favorite.where(post_id: post_ids).delete_all
    Post.where(id: post_ids).delete_all
    UserDataImport.where(id: import.id).delete_all
    UserStatus.for_user(admin.id).update_all(favorite_count: original_favorite_count)
  end

  def in_thread(&block)
    Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        CurrentUser.scoped(admin, &block)
      rescue StandardError => e
        e
      end
    end
  end

  def import_batch(ids)
    described_class.new(import.reload, token: token).send(:favorites_batch, ids.map { |id| [id, time] })
  end

  def counts_exact?
    admin.reload.user_status.favorite_count == Favorite.for_user(admin.id).count &&
      Post.where(id: post_ids).all? { |post| post.fav_count == Favorite.where(post_id: post.id).count }
  end

  # Pauses the thread that set Thread.current[flag] inside `method` until released.
  def pause_inside(klass, method, flag)
    reached = Queue.new
    release = Queue.new
    allow(klass).to receive(method).and_wrap_original do |original, *args, **kwargs, &blk|
      if Thread.current[flag]
        reached << true
        release.pop
      end
      original.call(*args, **kwargs, &blk)
    end
    [reached, release]
  end

  it "makes a favorite on a post in the batch wait for the import, without a deadlock" do
    reached, release = pause_inside(Favorite, :insert_all, :pause)
    importer = in_thread do
      Thread.current[:pause] = true
      import_batch(post_ids)
    end
    expect(reached.pop(timeout: 10)).to be(true) # the batch holds the post locks

    favoriter = in_thread { FavoriteManager.add!(user: admin, post: Post.find(post_ids.first)) }
    sleep(0.5)
    expect(favoriter).to be_alive # waiting on the post lock

    release << true
    inserted, _skipped, _generation = importer.value
    expect(inserted).to match_array(post_ids)
    expect(favoriter.value).to be_a(Favorite::Error)
    expect(favoriter.value.message).to eq("You have already favorited this post")
    expect(counts_exact?).to be(true)
  end

  it "makes the import wait for a favorite already in progress, then skips that post" do
    reached, release = pause_inside(Favorite, :create, :pause)
    favoriter = in_thread do
      Thread.current[:pause] = true
      FavoriteManager.add!(user: admin, post: Post.find(post_ids.first))
    end
    expect(reached.pop(timeout: 10)).to be(true) # add! holds the post lock

    importer = in_thread { import_batch(post_ids) }
    sleep(0.5)
    expect(importer).to be_alive # waiting on the post lock

    release << true
    expect(favoriter.value).not_to be_a(StandardError)
    inserted, _skipped, _generation = importer.value
    expect(inserted).to match_array(post_ids.drop(1))
    expect(counts_exact?).to be(true)
  end

  it "lets an unfavorite on a post in the batch finish after the import commits" do
    FavoriteManager.add!(user: admin, post: Post.find(post_ids.first))
    reached, release = pause_inside(Favorite, :insert_all, :pause)
    importer = in_thread do
      Thread.current[:pause] = true
      import_batch(post_ids)
    end
    expect(reached.pop(timeout: 10)).to be(true)

    remover = in_thread { FavoriteManager.remove!(user: admin, post: Post.find(post_ids.first)) }
    sleep(0.5)
    expect(remover).to be_alive

    release << true
    inserted, _skipped, _generation = importer.value
    expect(inserted).to match_array(post_ids.drop(1))
    expect(remover.value).not_to be_a(StandardError)
    expect(Favorite.for_user(admin.id).where(post_id: post_ids).pluck(:post_id)).to match_array(post_ids.drop(1))
    expect(counts_exact?).to be(true)
  end
end
