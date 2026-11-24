# frozen_string_literal: true

require "rails_helper"

RSpec.describe ImageSampler do
  let(:sm) { instance_double(StorageManager::Local) }
  let(:stored) { {} }

  before do
    allow(Danbooru.config.custom_configuration).to receive_messages(storage_manager: sm, small_image_width: 256)
    allow(sm).to receive(:store_avatar) do |io, _user_id, ext|
      copy = Tempfile.new(["stored", ".#{ext}"], binmode: true)
      FileUtils.cp(io.path, copy.path)
      stored[ext] = copy
    end
  end

  after { stored.each_value(&:close!) }

  describe ".generate_uploaded_avatar" do
    def generate_from(width, height, ext: ".png")
      Tempfile.create(["source", ext]) do |source|
        write_solid_image(source.path, width, height)
        described_class.generate_uploaded_avatar(source.path, 42)
      end
    end

    it "stores a jpg and a webp for the user" do
      generate_from(600, 300)
      expect(sm).to have_received(:store_avatar).with(anything, 42, "jpg")
      expect(sm).to have_received(:store_avatar).with(anything, 42, "webp")
    end

    it "crops a wide image to a square" do
      generate_from(600, 300)
      expect(image_dimensions(stored["jpg"].path)).to eq([256, 256])
      expect(image_dimensions(stored["webp"].path)).to eq([256, 256])
    end

    it "crops a tall image to a square" do
      generate_from(300, 900, ext: ".jpg")
      expect(image_dimensions(stored["jpg"].path)).to eq([256, 256])
    end

    it "scales a small image up to the avatar size" do
      generate_from(64, 64)
      expect(image_dimensions(stored["jpg"].path)).to eq([256, 256])
    end

    context "with a crop selection" do
      # A grey image with a blue square, to tell which part was cropped.
      def generate_with_square(width, height, square:, crop:)
        Tempfile.create(["source", ".png"]) do |source|
          Tempfile.create(["base", ".v"]) do |base|
            Tempfile.create(["square", ".v"]) do |blue|
              write_solid_image(base.path, width, height, color: [128, 128, 128])
              write_solid_image(blue.path, square[2], square[2], color: [0, 0, 255])
              VipsCommand.operation("insert", base.path, blue.path, source.path, square[0], square[1], timeout: 10)
            end
          end
          described_class.generate_uploaded_avatar(source.path, 42, crop: crop)
        end
      end

      def blue?(path, left, top)
        red, _green, blue = pixel_at(path, left, top)
        blue > 200 && red < 50
      end

      it "crops the selected square" do
        generate_with_square(600, 400, square: [300, 100, 200], crop: { x: 300, y: 100, w: 200 })
        expect(image_dimensions(stored["jpg"].path)).to eq([256, 256])
        expect(blue?(stored["jpg"].path, 10, 10)).to be true
        expect(blue?(stored["jpg"].path, 245, 245)).to be true
      end

      it "leaves out the rest of the image" do
        generate_with_square(600, 400, square: [300, 100, 200], crop: { x: 0, y: 0, w: 200 })
        expect(blue?(stored["jpg"].path, 128, 128)).to be false
      end

      it "lines the selection up on an image larger than the working size" do
        generate_with_square(5000, 1000, square: [4000, 0, 1000], crop: { x: 4000, y: 0, w: 1000 })
        expect(image_dimensions(stored["jpg"].path)).to eq([256, 256])
        expect(blue?(stored["jpg"].path, 5, 5)).to be true
        expect(blue?(stored["jpg"].path, 250, 250)).to be true
      end

      it "scales a small selection up to the avatar size" do
        generate_with_square(300, 300, square: [10, 10, 64], crop: { x: 10, y: 10, w: 64 })
        expect(image_dimensions(stored["jpg"].path)).to eq([256, 256])
        expect(blue?(stored["jpg"].path, 128, 128)).to be true
      end
    end

    it "refuses a file that isn't a supported image" do
      expect do
        described_class.generate_uploaded_avatar(file_fixture("staff_file.txt").to_s, 42)
      end.to raise_error(VipsCommand::UnsupportedFormat)
      expect(sm).not_to have_received(:store_avatar)
    end
  end
end
