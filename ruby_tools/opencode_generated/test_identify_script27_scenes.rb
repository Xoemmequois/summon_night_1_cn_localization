require "open3"

output, status = Open3.capture2e("ruby identify_script27_scenes.rb")
abort output unless status.success?

abort "FID 68 was not extracted\n#{output}" unless output.include?("FID 0x68: 53/53 texts extracted")

fid68 = File.binread("output_full/script27_fid68.txt")
abort "FID 68 contains empty groups" if fid68.match?(/--- Group \d+ \[[^\n]+\] ---\r?\n\r?\n/)
invalid_texts = fid68.scan(/TEXT:([0-9A-F]{4})/).map { |text| text[0].to_i(16) }.select { |text| text > 0x35 }
abort "FID 68 contains cross-FID text indices: #{invalid_texts.uniq}" unless invalid_texts.empty?

groups = fid68.split(/--- Group \d+ \[[^\r\n]+\] ---\r?\n/).drop(1).map do |group|
  group.scan(/TEXT:([0-9A-F]{4})/).flatten
end
abort "FID 68 did not join TEXT 001D-001F into one sentence" unless groups.include?(%w[001D 001E 001F])
abort "FID 68 retained reversed TEXT 001F,001E group" if groups.include?(%w[001F 001E])

puts "script27 FID 68 extraction regression check passed"
