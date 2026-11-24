# frozen_string_literal: true

require "rails_helper"

RSpec.describe ImageSampler do
  let(:files) { {} }

  before do
    allow(Danbooru.config.custom_configuration).to receive(:small_image_width).and_return(256)
  end

  after { files.each_value(&:close!) }

  describe ".uploaded_avatar_files" do
    def generate_from(width, height, ext: ".png")
      Tempfile.create(["source", ext]) do |source|
        write_solid_image(source.path, width, height)
        files.merge!(described_class.uploaded_avatar_files(source.path))
      end
    end

    it "makes a jpg and a webp" do
      generate_from(600, 300)
      expect(files.keys).to contain_exactly("jpg", "webp")
    end

    it "leaves out the photo's metadata" do
      files.merge!(described_class.uploaded_avatar_files(file_fixture("exif-orientation.jpg").to_s))
      expect(VipsCommand.header_field(files["jpg"].path, "exif-data")).to be_nil
      expect(VipsCommand.header_field(files["webp"].path, "exif-data")).to be_nil
    end

    it "crops a wide image to a square" do
      generate_from(600, 300)
      expect(image_dimensions(files["jpg"].path)).to eq([256, 256])
      expect(image_dimensions(files["webp"].path)).to eq([256, 256])
    end

    it "crops a tall image to a square" do
      generate_from(300, 900, ext: ".jpg")
      expect(image_dimensions(files["jpg"].path)).to eq([256, 256])
    end

    it "scales a small image up to the avatar size" do
      generate_from(64, 64)
      expect(image_dimensions(files["jpg"].path)).to eq([256, 256])
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
          files.merge!(described_class.uploaded_avatar_files(source.path, crop: crop))
        end
      end

      def blue?(path, left, top)
        red, _green, blue = pixel_at(path, left, top)
        blue > 200 && red < 50
      end

      it "crops the selected square" do
        generate_with_square(600, 400, square: [300, 100, 200], crop: { x: 300, y: 100, w: 200 })
        expect(image_dimensions(files["jpg"].path)).to eq([256, 256])
        expect(blue?(files["jpg"].path, 10, 10)).to be true
        expect(blue?(files["jpg"].path, 245, 245)).to be true
      end

      it "leaves out the rest of the image" do
        generate_with_square(600, 400, square: [300, 100, 200], crop: { x: 0, y: 0, w: 200 })
        expect(blue?(files["jpg"].path, 128, 128)).to be false
      end

      it "lines the selection up on an image larger than the working size" do
        generate_with_square(5000, 1000, square: [4000, 0, 1000], crop: { x: 4000, y: 0, w: 1000 })
        expect(image_dimensions(files["jpg"].path)).to eq([256, 256])
        expect(blue?(files["jpg"].path, 5, 5)).to be true
        expect(blue?(files["jpg"].path, 250, 250)).to be true
      end

      it "scales a small selection up to the avatar size" do
        generate_with_square(300, 300, square: [10, 10, 64], crop: { x: 10, y: 10, w: 64 })
        expect(image_dimensions(files["jpg"].path)).to eq([256, 256])
        expect(blue?(files["jpg"].path, 128, 128)).to be true
      end
    end

    it "refuses a file that isn't a supported image" do
      expect do
        described_class.uploaded_avatar_files(file_fixture("staff_file.txt").to_s)
      end.to raise_error(VipsCommand::UnsupportedFormat)
    end
  end
end
