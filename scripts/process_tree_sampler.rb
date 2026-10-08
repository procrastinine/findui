# Sample the sum of resident bytes in a command and its living descendants.
# Uses macOS libproc directly; no ps subprocesses or compiler are required.
# This is a sampled high-water mark, not physical memory (shared pages can be
# counted in more than one process), and very short-lived children can be missed.
require 'fiddle/import'
require 'set'

class ProcessTreeSampler
  module Libproc
    extend Fiddle::Importer
    dlload '/usr/lib/libproc.dylib'
    extern 'int proc_listchildpids(int, void *, int)'
    extern 'int proc_pidinfo(int, int, unsigned long long, void *, int)'
  end
  # Stable proc_taskinfo ABI: six uint64_t followed by twelve int32_t fields.
  TASK_BYTES = 96
  CHILD_LIMIT = 4096
  def initialize(pid, interval: 0.002)
    @pid, @interval = pid, interval
    @peak = @peak_count = @samples = 0
    @observed = Set.new
    @task_buffer = "\0".b * TASK_BYTES
    @child_buffer = "\0".b * (CHILD_LIMIT * 4)
    raise 'Cannot read macOS process memory' unless resident(Process.pid)
    @thread = Thread.new do
      until @stop
        sample
        sleep @interval
      end
    end
  end
  def resident(pid)
    length = Libproc.proc_pidinfo(pid, 4, 0, @task_buffer, TASK_BYTES)
    return nil if length.zero? # The process may have exited since enumeration.
    raise "Unexpected proc_taskinfo size: #{length}" unless length == TASK_BYTES
    @task_buffer.unpack('Q2')[1]
  end
  def sample
    queue = [@pid]
    seen = Set.new
    total = count = 0
    until queue.empty?
      pid = queue.pop
      next unless seen.add?(pid)
      children = Libproc.proc_listchildpids(pid, @child_buffer, @child_buffer.bytesize)
      raise 'Process-tree sample exceeded its child limit' if children >= CHILD_LIMIT
      queue.concat(@child_buffer.unpack("i#{children}").select(&:positive?)) if children.positive?
      if (bytes = resident(pid))
        total += bytes
        count += 1
        @observed << pid
      end
    end
    @peak = [@peak, total].max
    @peak_count = [@peak_count, count].max
    @samples += 1
  end
  def finish
    @stop = true
    @thread.value # Propagate a sampler failure instead of reporting zero memory.
    {sampledTreeRSSBytes: @peak, maximumConcurrentProcesses: @peak_count,
     observedProcesses: @observed.size, samples: @samples,
     intervalMilliseconds: @interval * 1000}
  end
end

if $PROGRAM_NAME == __FILE__
  require 'open3'
  require 'rbconfig'
  # Keep three actual processes alive together and touch their allocations.
  fixture = 'a="a"*16_777_216; fork { b="b"*33_554_432; fork { c="c"*33_554_432; sleep 0.4; exit!(c.size==0 ? 1 : 0) }; Process.wait; exit!(b.size==0 ? 1 : 0) }; Process.wait; exit!(a.size==0 ? 1 : 0)'
  Open3.popen3(RbConfig.ruby, '-e', fixture) do |input, output, error, wait|
    input.close
    sampler = ProcessTreeSampler.new(wait.pid)
    raise error.read unless wait.value.success?
    report = sampler.finish
    raise "Missed child/grandchild memory: #{report}" unless report[:maximumConcurrentProcesses] == 3 && report[:sampledTreeRSSBytes] >= 80 * 1024 * 1024
    puts "PASS: process-tree sampler observes simultaneous parent, child and grandchild allocations"
  end
end
