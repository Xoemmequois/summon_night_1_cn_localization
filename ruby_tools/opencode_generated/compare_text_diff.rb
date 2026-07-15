# Compare unique TEXT ids in output_full working tree vs git HEAD
# Usage: ruby compare_text_diff.rb

require 'set'

DIR = File.expand_path('output_full', __dir__)
REPO_ROOT = `git rev-parse --show-toplevel`.strip
REL_DIR = File.expand_path(DIR).sub(/^#{Regexp.escape(REPO_ROOT.gsub('\\', '/'))}\//i, '')
          .gsub('\\', '/')

TEXT_RE = /\[FID:([0-9A-Fa-f]+), TEXT:([0-9A-Fa-f]+)\]/

def extract_texts(content)
  set = Set.new
  content.scan(TEXT_RE) { |fid, tid| set << "#{fid.upcase}:#{tid.upcase}" }
  set
end

def git_head_content(rel_path)
  content = `git show "HEAD:#{rel_path}" 2>NUL`
  $?.success? ? content : nil
end

# collect file list from both working tree and HEAD
work_files = Dir.glob(File.join(DIR, 'script*_fid*.txt')).map { |f| File.basename(f) }
head_files = `git ls-tree --name-only "HEAD:#{REL_DIR}"`.split("\n")
                                                        .select { |f| f =~ /^script.*_fid.*\.txt$/ }

all_files = (work_files + head_files).uniq.sort

total_added = Set.new
total_removed = Set.new

all_files.each do |fname|
  work_path = File.join(DIR, fname)
  work_set = File.exist?(work_path) ? extract_texts(File.read(work_path, encoding: 'BINARY').force_encoding('UTF-8').scrub) : Set.new

  head_content = git_head_content("#{REL_DIR}/#{fname}")
  head_set = head_content ? extract_texts(head_content.force_encoding('UTF-8').scrub) : Set.new

  added = work_set - head_set
  removed = head_set - work_set
  next if added.empty? && removed.empty?

  total_added.merge(added)
  total_removed.merge(removed)

  puts "#{fname}: +#{added.size} -#{removed.size}"
  added.sort.each { |t| puts "  + [#{t}]" }
  removed.sort.each { |t| puts "  - [#{t}]" }
end

puts
puts "=== Summary ==="
puts "Unique TEXT added:   #{total_added.size}"
puts "Unique TEXT removed: #{total_removed.size}"
