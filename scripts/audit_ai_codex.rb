#!/usr/bin/env ruby
# Tests the installed Codex transport against a loopback fixture. No user login
# files, external model calls, prompts, or API credentials are used.
require 'socket'
require 'json'
require 'tmpdir'
require 'timeout'

root = File.expand_path('..', __dir__)
codex = ENV['FINDUI_CODEX'] || [File.expand_path('~/.local/bin/codex'), '/opt/homebrew/bin/codex', '/usr/local/bin/codex'].find { |path| File.executable?(path) }
abort 'Codex is unavailable. Set FINDUI_CODEX to its executable.' unless codex && File.executable?(codex)
source = File.read(File.join(root, 'Sources/SearchBackend/CodexSearchClient.swift'))
match = source.match(/static var isolatedConfiguration: \[String\] \{\s*\[(.*?)\]\s*\}/m)
abort 'Could not read the production isolation configuration.' unless match
configuration = JSON.parse('[' + match[1] + ']')

Dir.mktmpdir('findui-codex-fixture-') do |directory|
  server = TCPServer.new('127.0.0.1', 0)
  port = server.addr[1]
  args = ['exec', '--strict-config', '--ignore-user-config', '--ignore-rules', '--ephemeral', '--skip-git-repo-check',
          '--sandbox', 'read-only', '--cd', directory, '--color', 'never', '--json']
  fixture = ['features.enable_request_compression=false', 'model_provider="fixture"', 'model="fixture"',
             'model_providers.fixture.name="Local Test"', "model_providers.fixture.base_url=\"http://127.0.0.1:#{port}/v1\"",
             'model_providers.fixture.wire_api="responses"', 'model_providers.fixture.requires_openai_auth=false',
             'model_providers.fixture.request_max_retries=0', 'model_providers.fixture.stream_max_retries=0']
  (configuration + fixture).each { |value| args += ['-c', value] }
  args << 'Return {"ok":true}. Do not call any tools.'
  log = File.join(directory, 'codex.log')
  environment = { 'CODEX_HOME' => directory, 'OPENAI_API_KEY' => nil, 'CODEX_API_KEY' => nil, 'CODEX_ACCESS_TOKEN' => nil,
                  'OPENAI_BASE_URL' => nil, 'OPENAI_IDENTITY_TOKEN_FILE' => nil, 'OPENAI_AUDIENCE' => nil }
  pid = Process.spawn(environment, codex, *args, out: log, err: log, pgroup: true)
  begin
    socket = Timeout.timeout(20) { server.accept }
    headers = +''
    Timeout.timeout(5) { headers << socket.read(1) until headers.end_with?("\r\n\r\n") }
    length = headers[/content-length:\s*(\d+)/i, 1].to_i
    raise 'Unexpected fixture request length' unless (1..262_144).cover?(length)
    body = JSON.parse(socket.read(length))
    raise "Codex exposed tools: #{body['tools'].inspect}" unless body['tools'] == []
    raise 'Unexpected model destination' unless body['model'] == 'fixture'
    response = JSON.generate(error: { message: 'Local fixture stopped after verifying the request' })
    socket.write("HTTP/1.1 400 Bad Request\r\nContent-Type: application/json\r\nContent-Length: #{response.bytesize}\r\nConnection: close\r\n\r\n#{response}")
    socket.close
    Timeout.timeout(5) { Process.wait(pid) }
    puts 'PASS: Codex request exposes zero tools; isolated login store and loopback provider only.'
  rescue => error
    warn error.message
    warn File.read(log)[0, 4000]
    exit 1
  ensure
    Process.kill('TERM', -pid) rescue nil
    Process.wait(pid) rescue nil
    server.close
  end
end
