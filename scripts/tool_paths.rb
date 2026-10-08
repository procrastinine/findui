# Explicit environment overrides, PATH, then either Homebrew architecture.
def findui_tool(name)
  override=ENV[name.upcase.tr('-','_')]
  paths=override ? [override] : (ENV.fetch('PATH','').split(File::PATH_SEPARATOR)+%w[/opt/homebrew/bin /usr/local/bin /usr/bin /bin]).map { |folder|File.join(folder,name) }
  paths.find { |path|File.file?(path) && File.executable?(path) } || raise("Missing #{name}; install it or set #{name.upcase.tr('-','_')} to its executable path.")
end
