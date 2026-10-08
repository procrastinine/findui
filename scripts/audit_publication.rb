#!/usr/bin/env ruby
# Inspect exactly what Git would publish, including tracked-but-ignored files.
# Works before git init. Findings deliberately omit matched secret values.
require 'etc'
require 'digest'
require 'fileutils'
require 'find'
require 'json'
require 'open3'
require 'optparse'
require 'pathname'
require 'tmpdir'
require 'uri'

class PublicationAudit
  IMAGE_EXTENSIONS = %w[.png .jpg .jpeg .gif .tiff .tif .heic .webp .icns].freeze
  PRIVATE_COMPONENTS = %w[.git .cache .build .home .venv .venv-search-next backups training __pycache__].freeze
  GENERIC_USERS = %w[Shared Guest alice bob example user username you me runner root].freeze
  SECRET_RULES = {
    'API token' => /\b(?:sk-(?:or-v1-|proj-|ant-api\d+-)?[A-Za-z0-9_-]{24,}|gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{40,}|AIza[A-Za-z0-9_-]{30,}|AKIA[A-Z0-9]{16}|xox[baprs]-[A-Za-z0-9-]{20,})/,
    'private key' => /-----BEGIN (?:RSA |EC |OPENSSH |DSA |ENCRYPTED )?PRIVATE KEY-----/,
    'credential value' => /["'](?:client_secret|refresh_token|access_token|api_key)["']\s*[:=]\s*["'][A-Za-z0-9_+\/.=-]{32,}["']/,
    'embedded URL credentials' => %r{https?://[^\s/:'"]+:[^\s/@'"]+@([A-Za-z0-9.-]+)},
    'personal home path' => %r{(?:\A|[^\w])(?:/?Users/|/home/|(?:[A-Za-z]:)?\\Users\\)([A-Za-z0-9_.-]{2,})(?=[/\\\s"'<>]|\z)}
  }.freeze

  attr_reader :root, :findings, :files

  def initialize(root, account: Etc.getpwuid, home: Dir.home)
    @root = File.realpath(root)
    @findings = []
    @files = []
    @source_digests = {}
    @identities = [File.basename(home), account.name, account.gecos.split(',').first].compact
      .reject { |s| s.length < 5 || (GENERIC_USERS + %w[admin build codex developer]).include?(s) }.uniq
    @identity_pattern = @identities.empty? ? nil : /(?<![\p{Alnum}_])(?:#{@identities.map { |s| Regexp.escape(s) }.join('|')})(?![\p{Alnum}_])/i
  end

  def command(*argv, **options)
    out, _err, status = Open3.capture3(*argv, **options)
    raise "#{File.basename(argv.find { |a| a.is_a?(String) })} failed (output withheld to protect private values)" unless status.success?
    out
  end

  def candidates
    # No user-global excludes: another developer should get the same file set.
    env = { 'GIT_CONFIG_GLOBAL' => '/dev/null', 'GIT_CONFIG_NOSYSTEM' => '1',
            'GIT_DIR' => nil, 'GIT_WORK_TREE' => nil, 'GIT_INDEX_FILE' => nil }
    args = ['git', '-c', 'core.excludesFile=/dev/null', '-c', 'core.quotepath=false']
    list = if File.exist?(File.join(root, '.git'))
      command(env, *args, '-C', root, 'ls-files', '--cached', '--others', '--exclude-standard', '-z')
    else
      Dir.mktmpdir('findui-publication-git-') do |dir|
        command(env, 'git', 'init', '--bare', '--quiet', dir)
        command(env, *args, "--git-dir=#{dir}", "--work-tree=#{root}", 'ls-files', '--others', '--exclude-standard', '-z')
      end
    end
    list.split("\0").uniq.sort
  end

  def report(path, rule, line = nil)
    @findings << { file: path, rule: rule, line: line }.compact
  end

  def inspect_text(path, text, source: nil, emails: true)
    text = text.dup.force_encoding(Encoding::UTF_8).scrub
    # Include percent-encoded paths (URLs) and JSON-escaped path separators.
    variants = [text, URI::DEFAULT_PARSER.unescape(text).force_encoding(Encoding::UTF_8).scrub, text.gsub('\\/', '/')].uniq
    variants.each do |variant|
      variant.each_line.with_index(1) do |line, index|
        SECRET_RULES.each do |rule, pattern|
          next if rule == 'embedded URL credentials' && (!line.include?('://') || !line.include?('@'))
          next if rule == 'personal home path' && !line.include?('Users') && !line.include?('home')
          matches = line.to_enum(:scan, pattern).map { Regexp.last_match.dup }
          matches.reject! { |m| GENERIC_USERS.include?(m[1]) } if rule == 'personal home path'
          matches.reject! { |m| example_domain?(m[1]) } if rule == 'embedded URL credentials'
          report(path, [source, rule].compact.join(': '), index) unless matches.empty?
        end
        if @identity_pattern && line.match?(@identity_pattern)
          report(path, [source, 'local account identity'].compact.join(': '), index)
        end
        next unless emails && line.include?('@')
        # Preserve upstream license attribution; example domains are fixtures.
        next if path.match?(%r{(?:\A|/)(?:licenses|Licenses)/})
        line.scan(/[A-Z0-9._%+-]+@([A-Z0-9.-]+\.[A-Z]{2,})/i).flatten.each do |domain|
          next if example_domain?(domain)
          report(path, [source, 'email address requiring review'].compact.join(': '), index)
        end
      end
    end
  end

  def example_domain?(domain)
    domain.match?(/(?:\A|\.)example\.(?:com|org|net|test)\z/i) || domain.downcase.end_with?('.test', '.invalid')
  end

  def inspect_file(path, full, app: false)
    inspect_text(path, path, source: 'filename')
    if File.symlink?(full)
      target = File.readlink(full)
      inspect_text(path, target, source: 'symlink')
      resolved = File.expand_path(target, File.dirname(full))
      report(path, 'symlink leaves publication root') unless resolved.start_with?(root + '/')
      report(path, 'symlinks need explicit publication review')
      return
    end
    unless File.file?(full)
      report(path, 'missing or non-regular publication file')
      return
    end
    if !app && File.size(full) > 10 * 1024 * 1024
      report(path, 'unexpected large source artifact')
      return
    end
    bytes = File.binread(full)
    @source_digests[path] = Digest::SHA256.hexdigest(bytes) unless app
    image = IMAGE_EXTENSIONS.include?(File.extname(path).downcase)
    binary = bytes.include?("\0")
    unless app || image || !binary
      report(path, 'binary source artifact needs review')
    end
    inspect_text(path, binary ? bytes.scan(/[\x20-\x7e]{6,}/).join("\n") : bytes, emails: !binary)
    # UTF-16 paths may be embedded in binary metadata or Windows artifacts.
    if binary
      ['UTF-16LE', 'UTF-16BE'].each do |encoding|
        decoded = bytes.dup.force_encoding(encoding).encode('UTF-8', invalid: :replace, undef: :replace)
        inspect_text(path, decoded.scan(/[\x20-\x7e]{6,}/).join("\n"), emails: false)
      end
    end
  end

  def audit_source
    @files = candidates
    if File.exist?(File.join(root, '.git')) && !files.empty?
      ignored, _err, status = Open3.capture3(
        { 'GIT_CONFIG_GLOBAL' => '/dev/null', 'GIT_CONFIG_NOSYSTEM' => '1' },
        'git', '-C', root, '-c', 'core.excludesFile=/dev/null',
        'check-ignore', '--no-index', '--stdin', '-z', stdin_data: files.join("\0") + "\0")
      raise 'Could not check tracked ignored files' unless [0, 1].include?(status.exitstatus)
      ignored.split("\0").each { |path| report(path, 'tracked file matches publication ignore rules') }
    end
    files.each do |path|
      report(path, 'control character in filename') if path.match?(/[\x00-\x1f\x7f]/)
      components = path.split('/')
      if (components & PRIVATE_COMPONENTS).any? || path.match?(%r{(?:\A|/)(?:\.env(?:\..+)?|key\.txt|client_secret[^/]*\.json|credentials\.json|auth\.json|token\.json|\.netrc)\z}) && File.basename(path) != '.env.example'
        report(path, 'private artifact is publishable (possibly already tracked)')
      end
      inspect_file(path, File.join(root, path))
    end
    audit_images(files.select { |p| IMAGE_EXTENSIONS.include?(File.extname(p).downcase) }.map { |p| File.join(root, p) })
    @findings.uniq!
    self
  end

  def audit_images(paths)
    return if paths.empty?
    cache = File.join(root, '.cache', 'publication')
    FileUtils.mkdir_p(cache)
    helper = File.join(cache, 'image-audit')
    source = File.join(__dir__, 'audit_publication_images.swift')
    if !File.exist?(helper) || File.mtime(helper) < File.mtime(source)
      command('xcrun', 'swiftc', '-module-cache-path', '/tmp/findui-clang-module-cache', source, '-o', helper)
    end
    paths.each_slice(20) do |batch|
      records = JSON.parse(command(helper, *batch))
      records.each do |record|
        path = Pathname(record.fetch('path')).relative_path_from(Pathname(root)).to_s
        inspect_text(path, record.fetch('text'), source: 'image OCR')
        inspect_text(path, record.fetch('metadata'), source: 'image metadata')
        report(path, 'image GPS metadata') if record.fetch('gps')
      end
    end
  end

  def audit_app(directory)
    directory = File.realpath(directory)
    Find.find(directory) do |full|
      next if File.directory?(full) && !File.symlink?(full)
      path = Pathname(full).relative_path_from(Pathname(root)).to_s
      inspect_file(path, full, app: true)
    end
    @findings.uniq!
    self
  end

  def archive(destination)
    raise 'Refusing to archive files with unresolved privacy findings' unless findings.empty?
    raise 'Source file list changed after its publication audit; run the audit again' unless candidates == files
    destination = File.expand_path(destination)
    raise 'Source archives must be outside the source file set' if files.include?(Pathname(destination).relative_path_from(Pathname(root)).to_s)
    FileUtils.mkdir_p(File.dirname(destination))
    Dir.mktmpdir('findui-public-source-') do |staging|
      source = File.join(staging, 'FindUI')
      files.each do |path|
        target = File.join(source, path)
        FileUtils.mkdir_p(File.dirname(target))
        # Copy bytes and executable permissions, never extended attributes.
        bytes = File.binread(File.join(root, path))
        raise "Source changed after its publication audit: #{path}" unless Digest::SHA256.hexdigest(bytes) == @source_digests.fetch(path)
        File.write(target, bytes, mode: 'wb')
        File.chmod(File.stat(File.join(root, path)).mode & 0o777, target)
      end
      zip = File.join(staging, 'FindUI-source.zip')
      command('/usr/bin/zip', '-q', '-r', '-X', zip, 'FindUI', chdir: staging)
      archived = command('/usr/bin/unzip', '-Z1', zip).lines.map(&:chomp).reject { |p| p.end_with?('/') }.map { |p| p.delete_prefix('FindUI/') }.sort
      raise 'Source archive file list differs from audited source' unless archived == files
      command('/usr/bin/unzip', '-tqq', zip)
      unpacked = File.join(staging, 'unpacked')
      command('/usr/bin/unzip', '-q', zip, '-d', unpacked)
      files.each do |path|
        actual = Digest::SHA256.file(File.join(unpacked, 'FindUI', path)).hexdigest
        raise "Source archive bytes differ from audited source: #{path}" unless actual == @source_digests.fetch(path)
      end
      FileUtils.mv(zip, destination)
      File.write(destination + '.sha256', "#{Digest::SHA256.file(destination).hexdigest}  #{File.basename(destination)}\n")
    end
  end
end

if $PROGRAM_NAME == __FILE__
  options = { root: File.expand_path('..', __dir__) }
  OptionParser.new do |parser|
    parser.banner = 'Usage: ruby scripts/audit_publication.rb [--root DIR] [--app FindUI.app] [--archive ZIP]'
    parser.on('--root DIR') { |v| options[:root] = v }
    parser.on('--app DIR') { |v| options[:app] = v }
    parser.on('--archive ZIP') { |v| options[:archive] = v }
  end.parse!
  begin
    audit = PublicationAudit.new(options[:root]).audit_source
    audit.audit_app(options[:app]) if options[:app]
    if audit.findings.empty?
      puts "PASS: #{audit.files.length} publishable files; source, paths, credentials, image OCR and metadata checked#{options[:app] ? '; app bundle checked' : ''}."
      if options[:archive]
        audit.archive(options[:archive])
        puts "Created #{File.basename(options[:archive])} from exactly the audited source files."
      end
    else
      audit.findings.each { |f| puts "#{f[:file]}#{f[:line] ? ":#{f[:line]}" : ''}: #{f[:rule]}" }
      warn "FAIL: #{audit.findings.length} publication findings. Matched values are intentionally withheld."
      exit 1
    end
  rescue StandardError => error
    warn "Publication audit failed: #{error.message}"
    exit 1
  end
end
