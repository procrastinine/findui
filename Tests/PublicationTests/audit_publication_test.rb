require 'minitest/autorun'
require_relative '../../scripts/audit_publication'

class PublicationAuditTest < Minitest::Test
  def setup
    @root = Dir.mktmpdir('findui-publication-test-')
    @audit = PublicationAudit.new(@root)
  end

  def teardown
    FileUtils.remove_entry(@root)
  end

  def write(path, contents)
    full = File.join(@root, path)
    FileUtils.mkdir_p(File.dirname(full))
    File.binwrite(full, contents)
    full
  end

  def private_path
    File.join('/', 'Users', 'private-person', 'Documents', 'notes.txt')
  end

  def test_ignore_rules_work_before_git_init_and_do_not_initialize_workspace
    write('.gitignore', "/training/\n/key.txt\n/.cache/\n")
    write('README.md', 'Public source')
    write('training/checkpoint.bin', 'Local model')
    write('key.txt', 'Local key')
    write('.cache/data', 'Local cache')
    assert_equal ['.gitignore', 'README.md'], @audit.candidates
    refute File.exist?(File.join(@root, '.git'))
  end

  def test_tracked_ignored_file_is_rejected
    write('.gitignore', "/old-audit.txt\n")
    write('old-audit.txt', 'Formerly public')
    @audit.command('git', 'init', '--quiet', @root)
    @audit.command('git', '-C', @root, 'add', '-f', 'old-audit.txt')
    @audit.audit_source
    assert @audit.findings.any? { |f| f[:rule] == 'tracked file matches publication ignore rules' }
  end

  def test_plain_and_encoded_home_paths_are_rejected
    [private_path, private_path.gsub('/', '%2F'), private_path.gsub('/', '\\/')].each do |path|
      audit = PublicationAudit.new(@root)
      audit.inspect_text('fixture.txt', path)
      assert audit.findings.any? { |f| f[:rule] == 'personal home path' }
    end
  end

  def test_local_account_identity_is_detected_without_echoing_it
    @audit.inspect_text('fixture.txt', Dir.home)
    refute_empty @audit.findings
    refute JSON.generate(@audit.findings).include?(Dir.home)
  end

  def test_api_tokens_and_private_keys_are_rejected
    samples = ['sk-' + 'x' * 40, 'ghp_' + 'z' * 40,
               ['-----BEGIN ', 'PRIVATE KEY-----'].join,
               { refresh_token: 'r' * 60 }.to_json]
    samples.each do |sample|
      audit = PublicationAudit.new(@root)
      audit.inspect_text('fixture.txt', sample)
      refute_empty audit.findings
      refute JSON.generate(audit.findings).include?(sample)
    end
  end

  def test_real_email_and_url_credentials_need_review
    @audit.inspect_text('fixture.txt', ['someone', 'private-domain.org'].join('@'))
    @audit.inspect_text('fixture.txt', ['https://name:password', 'private-domain.org'].join('@'))
    assert @audit.findings.any? { |f| f[:rule].start_with?('email address') }
    assert @audit.findings.any? { |f| f[:rule] == 'embedded URL credentials' }
  end

  def test_synthetic_domains_and_system_shared_directory_are_allowed
    @audit.inspect_text('fixture.txt', 'https://user:password@api.example.test/v1 person@example.org /Users/Shared')
    assert_empty @audit.findings
  end

  def test_manual_home_key_markup_is_not_a_home_directory
    @audit.inspect_text('manual.txt', '\\fIctrl\\-home\\fR')
    assert_empty @audit.findings
  end

  def test_windows_home_path_is_rejected
    @audit.inspect_text('fixture.txt', ['C:', 'Users', 'private-person', 'Desktop'].join('\\'))
    assert @audit.findings.any? { |f| f[:rule] == 'personal home path' }
  end

  def test_license_attribution_is_retained_but_secrets_are_still_flagged
    @audit.inspect_text('docs/licenses/upstream.txt', ['author', 'project.org'].join('@'))
    assert_empty @audit.findings
    @audit.inspect_text('docs/licenses/upstream.txt', 'sk-' + 'x' * 40)
    refute_empty @audit.findings
  end

  def test_binary_utf16_home_paths_are_detected
    full = write('fixture.bin', "\0".b + private_path.encode('UTF-16LE').b)
    @audit.inspect_file('fixture.bin', full)
    assert @audit.findings.any? { |f| f[:rule] == 'personal home path' }
  end

  def test_symlink_cannot_bring_in_external_file
    File.symlink('/etc/hosts', File.join(@root, 'external'))
    @audit.audit_source
    assert @audit.findings.any? { |f| f[:rule] == 'symlink leaves publication root' }
  end

  def test_large_artifact_is_rejected_without_reading_it
    full = write('model.data', '')
    File.truncate(full, 11 * 1024 * 1024)
    @audit.audit_source
    assert @audit.findings.any? { |f| f[:rule] == 'unexpected large source artifact' }
  end

  def test_source_archive_contains_exactly_audited_files_and_no_private_files
    write('.gitignore', "/key.txt\n/dist/\n")
    write('README.md', 'Example')
    write('key.txt', 'private data')
    @audit.audit_source
    assert_empty @audit.findings
    zip = File.join(@root, 'dist', 'source.zip')
    @audit.archive(zip)
    listing = @audit.command('unzip', '-Z1', zip)
    assert_includes listing, 'FindUI/.gitignore'
    refute_includes listing, 'key.txt'
    assert_equal 'Example', @audit.command('unzip', '-p', zip, 'FindUI/README.md')
    assert_equal "#{Digest::SHA256.file(zip).hexdigest}  source.zip\n", File.read(zip + '.sha256')
  end

  def test_changed_source_cannot_bypass_the_completed_audit
    write('.gitignore', "/dist/\n")
    write('README.md', 'Public source')
    @audit.audit_source
    write('README.md', private_path)
    assert_raises(RuntimeError) { @audit.archive(File.join(@root, 'dist', 'source.zip')) }
    refute File.exist?(File.join(@root, 'dist', 'source.zip'))
  end

  def test_new_files_cannot_bypass_the_completed_audit
    write('.gitignore', "/dist/\n")
    write('README.md', 'Public source')
    @audit.audit_source
    write('later.txt', 'Added after review')
    assert_raises(RuntimeError) { @audit.archive(File.join(@root, 'dist', 'source.zip')) }
  end

  def test_archive_is_blocked_by_findings
    write('notes.txt', private_path)
    @audit.audit_source
    assert_raises(RuntimeError) { @audit.archive(File.join(@root, 'source.zip')) }
  end

  def test_ocr_detects_a_path_in_actual_image_pixels
    # Built-in macOS drawing and Vision; no external OCR or image service.
    source = write('fixture.swift', <<~SWIFT)
      import Foundation
      import CoreGraphics
      import CoreText
      import ImageIO
      let context = CGContext(data: nil, width: 1400, height: 180, bitsPerComponent: 8, bytesPerRow: 0,
          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
      context.setFillColor(CGColor(gray: 1, alpha: 1))
      context.fill(CGRect(x: 0, y: 0, width: 1400, height: 180))
      let text = NSAttributedString(string: CommandLine.arguments[2], attributes: [
          NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Menlo" as CFString, 38, nil),
          NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1)])
      context.textPosition = CGPoint(x: 30, y: 70)
      CTLineDraw(CTLineCreateWithAttributedString(text), context)
      let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: CommandLine.arguments[1]) as CFURL, "public.png" as CFString, 1, nil)!
      CGImageDestinationAddImage(destination, context.makeImage()!, nil)
      guard CGImageDestinationFinalize(destination) else { exit(1) }
    SWIFT
    renderer = File.join(@root, 'render-fixture')
    @audit.command('xcrun', 'swiftc', '-module-cache-path', '/tmp/findui-clang-module-cache', source, '-o', renderer)
    png = File.join(@root, 'screenshot.png')
    @audit.command(renderer, png, private_path)
    @audit.audit_images([png])
    assert @audit.findings.any? { |f| f[:rule] == 'image OCR: personal home path' }
    refute JSON.generate(@audit.findings).include?(private_path)
  end
end
