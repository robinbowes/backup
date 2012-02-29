# encoding: utf-8

module Backup
  class Pipeline
    include Backup::CLI::Helpers

    attr_reader :stderr, :errors

    def initialize
      @commands = []
      @errors = []
      @stderr = ''
    end

    ##
    # Adds a command to be executed in the pipeline.
    # Each command will be run in the order in which it was added,
    # with it's output being piped to the next command.
    def <<(command)
      @commands << command
    end

    ##
    # Runs the command line from `#pipeline` and collects STDOUT/STDERR.
    # STDOUT is then parsed to determine the exit status of each command.
    # For each command with a non-zero exit status, a SystemCallError is
    # created and added to @errors. All STDERR output is set in @stderr.
    #
    # Note that there is no accumulated STDOUT from the commands,
    # and the last command added to the pipeline should *not* attempt to
    # write to STDOUT, as this will raise an Exception.
    #
    # Use `#success?` to determine if all commands in the pipeline succeeded.
    # If `#success?` returns `false`, use `#error_messages` to get an error report.
    def run
      Open4.popen4(pipeline) do |pid, stdin, stdout, stderr|
        pipestatus = stdout.read.gsub("\n", '').split(':').sort
        pipestatus.each do |status|
          index, exitstatus = status.split('|').map(&:to_i)
          if exitstatus > 0
            command = command_name(@commands[index])
            @errors << SystemCallError.new(
              "'#{ command }' returned exit code: #{ exitstatus }", exitstatus
            )
          end
        end
        @stderr = stderr.read.strip
      end
      Logger.warn(stderr_messages) if success? && stderr_messages
    rescue Exception => e
      raise Errors::Pipeline::ExecutionError.wrap(e)
    end

    def success?
      @errors.empty?
    end

    ##
    # Returns a multi-line String, reporting all STDERR messages received
    # from the commands in the pipeline (if any), along with the SystemCallError
    # (Errno) message for each command which had a non-zero exit status.
    #
    # Each error is wrapped by Backup::Errors to provide formatting.
    def error_messages
      @error_messages ||= (stderr_messages || '') +
          "The following system errors were returned:\n" +
          @errors.map {|err| Errors::Error.wrap(err).message }.join("\n")
    end

    private

    ##
    # Each command is added as part of the pipeline, grouped with an `echo`
    # command to pass along the command's index in @commands and it's exit status.
    # The command's STDERR is redirected to FD#4, and the `echo` command to
    # report the "index|exit status" it redirected to FD#3.
    # Each command's STDOUT will be connected to the STDIN of the next subshell.
    # The entire pipeline is run within a container group, which redirects
    # FD#3 to STDOUT and FD#4 to STDERR so these can be collected.
    # FD#1 is closed so any attempt by the last command in the pipeline to
    # write to STDOUT will raise an error, as we don't want this to interfere
    # with collecting the exit statuses.
    #
    # There is no guarantee as to the order of this output, which is why the
    # command's index in @commands is passed along with it's exit status.
    # And, if multiple commands output messages on STDERR, those messages
    # may be interleaved. Interleaving of the "index|exit status" outputs
    # should not be an issue, given the small byte size of the data being written.
    def pipeline
      parts = []
      @commands.each_with_index do |command, index|
        parts << %Q[( #{ command } 2>&4; echo "#{ index }|$?:" >&3 )]
      end
      "( #{ parts.join(' | ') } ) 3>&1- 4>&2"
    end

    def stderr_messages
      @stderr_messages ||= @stderr.empty? ? false : <<-EOS.gsub(/^ +/, '  ')
        Pipeline STDERR Messages:
        (Note: may be interleaved if multiple commands returned error messages)

        #{ @stderr }
      EOS
    end

  end
end