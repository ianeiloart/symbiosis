
require "fileutils"

module Symbiosis

  #
  # This module has a number of useful methods that are used everywhere.
  #
  module Utils

    # 
    # This function uses the FileUtils mkdir_p command to make a directory.
    # It adds the extra options of :uid and :gid to allow these to be set in
    # one fell swoop.
    #
    # This has been written to avoid the TOCTTOU race conditions between
    # creating a directory, and chowning it, to make sure that we don't
    # accidentally chown a file on the end of a symlink
    #
    # It returns the name of the directory created.
    #
    def mkdir_p(dir, options = {})
      # Switch on verbosity..
      options[:verbose] = true if $DEBUG

      # Find the first directory that exists, and the first non-existent one.
      parent = File.expand_path(dir)

      begin
        #
        # Check the parent.
        #
        lstat_parent = File.lstat(parent)
      rescue Errno::ENOENT
        lstat_parent = nil
      end

      return parent if !lstat_parent.nil? and lstat_parent.directory?

      #
      # Awooga, something already in the way.
      #
      raise Errno::EEXIST, parent unless lstat_parent.nil?

      #
      # Break down the directory until we find one that exists.
      #
      stack = []
      while !File.exists?(parent)
        stack.unshift parent
        parent = File.dirname(parent)
      end

      # 
      # Then set the options such that the uid/gid of the parent dir can be
      # propagated, but only if we're root.
      #
      if (options[:uid].nil? or options[:gid].nil?) and 0 == Process.euid
        parent_s = File.stat(parent)
        options[:gid] = parent_s.gid if options[:gid].nil?
        options[:uid] = parent_s.uid if options[:uid].nil?
      end

      #
      # Set up a sensible mode
      #
      unless options[:mode].is_a?(Integer)
        options[:mode] = (0777 - File.umask)
      end

      #
      # Create our stack of directories in real life.
      #
      stack.each do |dir|
        begin
          #
          # If a symlink (or anything else) is in the way, an EEXIST exception
          # is raised.
          #
          Dir.mkdir(dir, options[:mode])
        rescue Errno::EEXIST => err
          #
          # If there is a directory in our way, skip and move on.  This could
          # be a TOCTTOU problem.
          #
          next if File.directory?(dir)

          #
          # Otherwise barf.
          #
          raise err
        end

        #
        # Use lchown to prevent accidentally chowning the target of a symlink,
        # instead chowning the symlink itself.  This mitigates a TOCTTOU race
        # condition where the attacker replaces our new directory with a
        # symlink to a file he can't read, only to have us chown it.
        #
        File.lchown(options[:uid], options[:gid], dir)
      end

      return dir
    end

    # 
    # This function generates a string of random numbers and letters from the
    # sequence A-Z, a-z, 0-9 minus 0, O, o, 1, I, i, l.
    #
    def random_string( len = 10 )
      raise ArgumentError, "length must be an integer" unless len.is_a?(Integer)

      randchars = "23456789abcdefghjkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ"

      name=""

      len.times { name << randchars[rand(randchars.length)] }

      name
    end

    #
    # Allow arbitrary parameters in parent_dir to be retrieved.
    #
    # * false is returned if the file does not exist, or is not readable
    # * true is returned if the file exists, but is of zero length
    # * otherwise the files contents are returned as a string.
    #
    #
    def get_param(setting, parent_dir)
      fn = File.join(parent_dir, setting)

      #
      # Return false unless we can read the file
      #
      return false unless File.exists?(fn) and File.readable?(fn)

      #
      # Return true if the file is present and empty
      #
      return true if File.zero?(fn)

      #
      # Otherwise return the contents
      #
      return File.open(fn, "r"){|fh| fh.read}.to_s
    end

    #
    # Records a parameter.
    #
    # * true is stored as an empty file
    # * false or nil causes the file to be removed, if it exists.
    # * Anything else is converted to a string and stored.
    #
    # If a file is created, or written to, then the permissions are set such
    # that the file is owned by the same owner/group as the parent_dir, and
    # readable by everyone, but writable only by the owner (0644).
    #
    # Directories owned by system users/groups will not be written to.
    #
    def set_param(setting, value, parent_dir)
      fn = File.join(parent_dir, setting)

      #
      # Make sure the directory exists first
      #
      raise "Config directory does not exist." unless File.exists?(parent_dir)

      #
      # Check the parent directory.
      #
      parent_dir_stat = File.stat(parent_dir)

      #
      # Refuse to write to directories owned by UIDs/GIDs < 1000.
      #
      raise ArgumentError, "Parent directory #{parent_dir} is owned by a system user." unless parent_dir_stat.uid >= 1000
      raise ArgumentError, "Parent directory #{parent_dir} is owned by a system group." unless parent_dir_stat.gid >= 1000


      if false == value or value.nil?
        #
        # This doesn't follow symlinks.
        #
        File.unlink(fn) if File.exists?(fn)

      else
        #
        # Create the file/
        #

        safe_open(fn, File::WRONLY|File::CREAT, :mode => 0644, :uid => parent_dir_stat.uid, :gid => parent_dir_stat.gid) do |fh|
          #
          # We're good to go.
          #
          fh.truncate(0)
          
          #
          # Record the value
          #
          fh.write(value.to_s) unless true == value
        end

      end

      #
      # Return the value we were originally given
      #
      value
    end

    #
    # This method opens a file in a safe manner, avoiding symlink attacks and
    # TOCTTOU race conditions.
    #
    # The mode can be a string or an integer, but must not be "w" or "w+", or
    # have File::TRUNC set, to avoid truncating the file on opening.
    #
    # +opts+ is an options hash in which the uid, gid, and mode file bits can
    # be specified.
    # 
    # * :uid is the User ID, e.g. 1000.
    # * :gid is the Group ID, e.g. 1000.
    # * :mode is the permissions, e.g. 0644.
    #
    # By default mode is set using the current umask.  
    #
    def safe_open(file, mode = File::RDONLY, opts = {}, &block)
      #
      # Make sure the mode doesn't automatically truncate the file
      #
      if mode.is_a?(String)
        raise Errno::EPERM, "Bad mode string #{mode.inspect} for opening a file safely." if %w(w w+).include?(mode)

      elsif mode.is_a?(Integer)
        raise Errno::EPERM, "Bad mode string #{mode.inspect} for opening a file safely." if (File::TRUNC == (mode & File::TRUNC))

      else
        raise ArgumentError, "Bad mode #{mode.inspect}"

      end

      #
      # set some default options
      #
      opts = {:uid => nil, :gid => nil, :mode => (0666 - File.umask)}.merge(opts)

      #
      # Set up our filehandle object.
      #
      fh = nil

      begin  
        #
        # This will raise an error if we can't open the file
        #
        fh = File.open(file, mode, opts[:mode])

        #
        # Check to see if we've opened a symlink.
        #
        link_stat = fh.lstat
        file_stat = fh.stat
  
        if link_stat.symlink? and file_stat.uid != link_stat.uid
          #
          # uh-oh .. symlink pointing at a file owned by someone else?
          #
          raise Errno::EPERM, file
        end

        #
        # Change the uid/gid as needed.
        #
        if ((opts[:uid] and file_stat.uid != opts[:uid]) or 
         (opts[:gid] and file_stat.gid != opts[:gid]))
          #
          # Change the owner if not already correct
          #
          fh.chown(opts[:uid], opts[:gid]) unless link_stat.symlink?
        end

        if opts[:mode] 
          #
          # Fix any permissions.
          #
          fh.chmod(opts[:mode]) unless link_stat.symlink?
        end

      rescue ArgumentError, IOError, SystemCallError => err

        fh.close unless fh.nil? or fh.closed?
        raise err
      end

      if block_given?
        begin
          #
          # Yield the block, and then close the file.
          #
          yield fh
        ensure
          #
          # Close the file, if possible.
          #
          fh.close unless fh.nil? or fh.closed?
        end
      else
        #
        # Just return the file handle.
        #
        return fh
      end
      
    end

    #
    # If a numeric argument is given, it is rounded to the nearest whole
    # number, and returned as an Integer.
    #
    # If a string is given, the method attempts to parse it.  The quota can be
    # a decimal, followed optionally by a space, and optionally by a "prefix".
    # Prefixes it understands are:
    #
    #  * k, M, G, T, P as powers of 10
    #  * ki, Mi, Gi, Ti, Pi as powers of 2.
    # 
    # The answer is given as an Integer.
    #
    # An argument error is given if the string cannot be parsed, or the
    # argument is neither a Numeric or String object.
    #
    def parse_quota(quota)
      if quota.is_a?(Numeric)
        return quota.round.to_i
 
      elsif quota.is_a?(String) and quota =~ /^\s*([\d\.]+)\s*([bkMGTP]i?)?/

        n = $1.to_f
        m = case $2
          when "k": 1e3
          when "M": 1e6
          when "G": 1e9
          when "T": 1e12
          when "P": 1e15
          when "ki": 2**10
          when "Mi": 2**20
          when "Gi": 2**30
          when "Ti": 2**40
          when "Pi": 2**50
          else 1
        end

        return (n*m).round.to_i
      elsif quota.is_a?(String)
        raise ArgumentError, "Cannot parse quota #{quota.inspect}"
      else
        raise ArgumentError, "parse_quota requires either a String or Numeric argument"
      end
    end

    module_function :mkdir_p, :set_param, :get_param, :random_string, :safe_open, :parse_quota

  end

end

