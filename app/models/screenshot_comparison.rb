require './lib/image_geometry'

class ScreenshotComparison
  attr_reader :pass

  def initialize(test, screenshot)
    determine_baseline_test(test, screenshot)
    image_paths = temp_screenshot_paths(test)
    compare_result = compare_images(test, image_paths)
    @pass = determine_pass(test, image_paths, compare_result)
    test.pass = @pass
    save_or_discard_screenshots(test, image_paths)
    remove_temp_files(image_paths)
  end

  private

  def temp_screenshot_paths(test)
    {
      baseline: File.join(Rails.root, 'tmp', "#{test.id}_baseline.png"),
      test: File.join(Rails.root, 'tmp', "#{test.id}_test.png"),
      diff: File.join(Rails.root, 'tmp', "#{test.id}_diff.png")
    }
  end

  def compare_images(test, image_paths)
    canvas = create_canvas(test)
    baseline_resize_command = convert_image_command(test.screenshot_baseline.path, image_paths[:baseline], canvas.to_h)
    test_size_command = convert_image_command(test.screenshot.path, image_paths[:test], canvas.to_h)
    compare_command = compare_images_command(image_paths[:baseline], image_paths[:test], image_paths[:diff], test.fuzz_level, 'red')
    # run all commands in serial
    Open3.popen3("#{baseline_resize_command} && #{test_size_command} && #{compare_command}") { |_stdin, _stdout, stderr, _wait_thr| stderr.read }
  end

  def compare_images_command(baseline_file, compare_file, diff_file, fuzz, highlight_colour)
    "compare -alpha Off -dissimilarity-threshold 1 -fuzz #{fuzz} -metric AE -highlight-color #{highlight_colour} #{baseline_file.shellescape} #{compare_file.shellescape} #{diff_file.shellescape}"
  end

  def create_canvas(test)
    # create a canvas using the baseline's dimensions
    Canvas.new(
      ImageGeometry.new(test.screenshot_baseline.path),
      ImageGeometry.new(test.screenshot.path)
    )
  end

  def determine_baseline_test(test, screenshot)
    # find an existing baseline screenshot for this test
    baseline_test = Test.find_baseline_by_key(test.key)

    if baseline_test
      # grab the existing baseline image and cache it against this test
      test.screenshot_baseline = baseline_test.screenshot
    else
      # otherwise if no baseline exists (i.e. this is the first run of this test), mark test as the baseline
      test.baseline = true
      test.screenshot_baseline = screenshot
    end
    test.save!
  end

  def convert_image_command(input_file, output_file, canvas)
    "convert #{input_file.shellescape} -background white -extent #{canvas[:width]}x#{canvas[:height]} #{output_file.shellescape}"
  end

  def determine_pass(test, image_paths, compare_result)
    begin
      img_size = ImageSize.path(image_paths[:diff]).size.inject(:*)
      pixel_count = (compare_result.to_f / img_size) * 100
      test.diff = pixel_count.round(2)
      # TODO: pull out 0.1 (diff threshhold to config variable)
      (test.diff < 0.1)
    rescue
      # should probably raise an error here
    end
  end

  def save_or_discard_screenshots(test, image_paths)
    if test.pass == true && test.baseline == false
      # don't store screenshots for passing tests that aren't baselines
      test.screenshot = nil
      test.screenshot_baseline = nil
      test.screenshot_diff = nil
    else
      # assign temporary images to the test to allow dragonfly to process and persist
      test.screenshot = Pathname.new(image_paths[:test])
      test.screenshot_baseline = Pathname.new(image_paths[:baseline])
      test.screenshot_diff = Pathname.new(image_paths[:diff])
    end

    test.save
  end

  def remove_temp_files(image_paths)
    # remove the temporary files
    File.delete(image_paths[:test])
    File.delete(image_paths[:baseline])
    File.delete(image_paths[:diff])
  end
end
