require 'fileutils'
require 'pathname'
require 'spaceship'
require 'rubygems/version'
require 'xcode/install/command'
require 'xcode/install/version'

module XcodeInstall
  class Curl
    COOKIES_PATH = Pathname.new('/tmp/curl-cookies.txt')

    def fetch(url, directory = nil, cookies = nil, output = nil, progress = true)
      options = cookies.nil? ? '' : "-b '#{cookies}' -c #{COOKIES_PATH}"
      # options += ' -vvv'

      uri = URI.parse(url)
      output ||= File.basename(uri.path)
      output = (Pathname.new(directory) + Pathname.new(output)) if directory

      progress = progress ? '-#' : '-s'
      command = "curl #{options} -L -C - #{progress} -o #{output} #{url}"
      IO.popen(command).each do |fd|
        puts(fd)
      end
      result = $CHILD_STATUS.to_i == 0

      FileUtils.rm_f(COOKIES_PATH)
      result
    end
  end

  class Installer
    attr_reader :xcodes

    def initialize
      FileUtils.mkdir_p(CACHE_DIR)
    end

    def cache_dir
      CACHE_DIR
    end

    def current_symlink
      File.symlink?(SYMLINK_PATH) ? SYMLINK_PATH : nil
    end

    def download(version, progress, url = nil)
      return unless exist?(version) || url
      xcode = seedlist.find { |x| x.name == version }
      dmg_file = Pathname.new(File.basename(url || xcode.path))

      result = Curl.new.fetch(url || xcode.url, CACHE_DIR, spaceship.cookie, dmg_file, progress)
      result ? CACHE_DIR + dmg_file : nil
    end

    def exist?(version)
      list_versions.include?(version)
    end

    def installed?(version)
      installed_versions.map(&:version).include?(version)
    end

    def installed_versions
      @installed ||= installed.map { |x| InstalledXcode.new(x) }.sort do |a, b|
        Gem::Version.new(a.version) <=> Gem::Version.new(b.version)
      end
    end

    def install_dmg(dmgPath, suffix = '', switch = true, clean = true)
      xcode_path = "/Applications/Xcode#{suffix}.app"

      `hdiutil mount -nobrowse -noverify #{dmgPath}`
      puts 'Please authenticate for Xcode installation...'
      source =  Dir.glob('/Volumes/Xcode/Xcode*.app').first

      if source.nil?
        out <<-HELP
No `Xcode.app` found in DMG. Please remove #{dmgPath} if you suspect a corrupted
download or run `xcversion update` to see if the version you tried to install
has been pulled by Apple. If none of this is true, please open a new GH issue.
HELP
        $stderr.puts out.gsub("\n", ' ')
        return
      end

      `sudo ditto "#{source}" "#{xcode_path}"`
      `umount "/Volumes/Xcode"`

      if not verify_integrity(xcode_path)
        `sudo rm -f #{xcode_path}`
        return
      end

      enable_developer_mode
      xcode = InstalledXcode.new(xcode_path)
      xcode.approve_license
      xcode.install_components

      if switch
        `sudo rm -f #{SYMLINK_PATH}` unless current_symlink.nil?
        `sudo ln -sf #{xcode_path} #{SYMLINK_PATH}` unless SYMLINK_PATH.exist?

        `sudo xcode-select --switch #{xcode_path}`
        puts `xcodebuild -version`
      end

      FileUtils.rm_f(dmgPath) if clean
    end

    def install_version(version, switch = true, clean = true, install = true, progress = true, url = nil)
      dmg_path = get_dmg(version, progress, url)
      fail Informative, "Failed to download Xcode #{version}." if dmg_path.nil?

      install_dmg(dmg_path, "-#{version.split(' ')[0]}", switch, clean) if install

      open_release_notes_url(version)
    end

    def open_release_notes_url(version)
      return if version.nil?
      xcode = seedlist.find { |x| x.name == version }
      `open #{xcode.release_notes_url}` unless xcode.nil? || xcode.release_notes_url.nil?
    end

    def list_current
      stable_majors = list_versions.reject { |v| /beta/i =~ v }.map { |v| v.split('.')[0] }.map { |v| v.split(' ')[0] }
      latest_stable_major = stable_majors.select { |v| v.length == 1 }.uniq.sort.last.to_i
      list_versions.select { |v| v.split('.')[0].to_i >= latest_stable_major }.sort.join("\n")
    end

    def list
      list_versions.join("\n")
    end

    def rm_list_cache
      FileUtils.rm_f(LIST_FILE)
    end

    def symlink(version)
      xcode = installed_versions.find { |x| x.version == version }
      `sudo rm -f #{SYMLINK_PATH}` unless current_symlink.nil?
      `sudo ln -sf #{xcode.path} #{SYMLINK_PATH}` unless xcode.nil? || SYMLINK_PATH.exist?
    end

    def symlinks_to
      File.absolute_path(File.readlink(current_symlink), SYMLINK_PATH.dirname) if current_symlink
    end

    private

    def spaceship
      @spaceship ||= begin
        begin
          Spaceship.login(ENV["XCODE_INSTALL_USER"], ENV["XCODE_INSTALL_PASSWORD"])
        rescue Spaceship::Client::InvalidUserCredentialsError
          $stderr.puts 'The specified Apple developer account credentials are incorrect.'
          exit(1)
        rescue Spaceship::Client::NoUserCredentialsError
          $stderr.puts <<-HELP
Please provide your Apple developer account credentials via the
XCODE_INSTALL_USER and XCODE_INSTALL_PASSWORD environment variables.
HELP
          exit(1)
        end

        if ENV.key?("XCODE_INSTALL_TEAM_ID")
          Spaceship.client.team_id = ENV["XCODE_INSTALL_TEAM_ID"]
        end
        Spaceship.client
      end
    end

    CACHE_DIR = Pathname.new("#{ENV['HOME']}/Library/Caches/XcodeInstall")
    LIST_FILE = CACHE_DIR + Pathname.new('xcodes.bin')
    MINIMUM_VERSION = Gem::Version.new('4.3')
    SYMLINK_PATH = Pathname.new('/Applications/Xcode.app')

    def enable_developer_mode
      `sudo /usr/sbin/DevToolsSecurity -enable`
      `sudo /usr/sbin/dseditgroup -o edit -t group -a staff _developer`
    end

    def get_dmg(version, progress = true, url = nil)
      if url
        path = Pathname.new(url)
        return path if path.exist?
      end
      if ENV.key?('XCODE_INSTALL_CACHE_DIR')
        cache_path = Pathname.new(ENV['XCODE_INSTALL_CACHE_DIR']) + Pathname.new("xcode-#{version}.dmg")
        return cache_path if cache_path.exist?
      end

      download(version, progress, url)
    end

    def fetch_seedlist
      @xcodes = parse_seedlist(spaceship.send(:request, :get, '/services-account/QH65B2/downloadws/listDownloads.action', {
        start: "0",
        limit: "1000",
        sort: "dateModified",
        dir: "DESC",
        searchTextField: "",
        searchCategories: "",
        search: "false",
      }).body)

      names = @xcodes.map(&:name)
      @xcodes += prereleases.reject { |pre| names.include?(pre.name) }

      File.open(LIST_FILE, 'w') do |f|
        f << Marshal.dump(xcodes)
      end

      xcodes
    end

    def installed
      unless (`mdutil -s /` =~ /disabled/).nil?
        $stderr.puts 'Please enable Spotlight indexing for /Applications.'
        exit(1)
      end

      `mdfind "kMDItemCFBundleIdentifier == 'com.apple.dt.Xcode'" 2>/dev/null`.split("\n")
    end

    def parse_seedlist(seedlist)
      seeds = Array(seedlist['downloads']).select do |t|
        /^Xcode [0-9]/.match(t['name'])
      end

      xcodes = seeds.map { |x| Xcode.new(x) }.reject { |x| x.version < MINIMUM_VERSION }.sort do |a, b|
        a.date_modified <=> b.date_modified
      end

      xcodes.select { |x| x.url.end_with?('.dmg') }
    end

    def list_versions
      installed = installed_versions.map(&:version)
      seedlist.map(&:name).reject { |x| installed.include?(x) }
    end

    def prereleases
      body=spaceship.send(:request, :get, '/xcode/download/').body
      links=body.scan(/<a.+?href="(.+?.dmg)".*>(.*)<\/a>/)
      links = links.map do |link|
        parent = link[0].scan(/path=(\/.*\/.*\/)/).first.first
        match = body.scan(/#{Regexp.quote(parent)}(.+?.pdf)/).first
        if match
          link += [parent + match.first]
        else
          link += [nil]
        end
      end
      links.map { |pre| Xcode.new_prerelease(pre[1].strip.gsub(/.*Xcode /, ''), pre[0], pre[2]) }
    end

    def seedlist
      @xcodes = Marshal.load(File.read(LIST_FILE)) if LIST_FILE.exist? && xcodes.nil?
      xcodes || fetch_seedlist
    end

    def verify_integrity(path)
      puts `/usr/sbin/spctl --assess --verbose=4 --type execute #{path}`
      $?.exitstatus == 0
    end
  end

  class InstalledXcode
    attr_reader :path
    attr_reader :version

    def initialize(path)
      @path = Pathname.new(path)
      @version = get_version
    end

    def approve_license
      license_path = "#{@path}/Contents/Resources/English.lproj/License.rtf"
      license_id = IO.read(license_path).match(/^EA\d{4}/)
      license_plist_path = '/Library/Preferences/com.apple.dt.Xcode.plist'
      `sudo rm -rf #{license_plist_path}`
      `sudo /usr/libexec/PlistBuddy -c "add :IDELastGMLicenseAgreedTo string #{license_id}" #{license_plist_path}`
      `sudo /usr/libexec/PlistBuddy -c "add :IDEXcodeVersionForAgreedToGMLicense string #{@version}" #{license_plist_path}`
    end

    def install_components
      `sudo installer -pkg #{@path}/Contents/Resources/Packages/MobileDevice.pkg -target /`
      osx_build_version = `sw_vers -buildVersion`.chomp
      tools_version = `/usr/libexec/PlistBuddy -c "Print :ProductBuildVersion" "#{@path}/Contents/version.plist"`.chomp
      cache_dir = `getconf DARWIN_USER_CACHE_DIR`.chomp
      `touch #{cache_dir}com.apple.dt.Xcode.InstallCheckCache_#{osx_build_version}_#{tools_version}`
    end

    :private

    def get_version
      output = `DEVELOPER_DIR='' "#{@path}/Contents/Developer/usr/bin/xcodebuild" -version`
      return '0.0' if output.nil? # ¯\_(ツ)_/¯
      output.split("\n").first.split(' ')[1]
    end
  end

  class Xcode
    attr_reader :date_modified
    attr_reader :name
    attr_reader :path
    attr_reader :url
    attr_reader :version
    attr_reader :release_notes_url

    def initialize(json)
      @date_modified = json['dateModified'].to_i
      @name = json['name'].gsub(/^Xcode /, '')
      @path = json['files'].first['remotePath']
      url_prefix = 'https://developer.apple.com/devcenter/download.action?path='
      @url = "#{url_prefix}#{@path}"
      @release_notes_url = "#{url_prefix}#{json['release_notes_path']}" if json['release_notes_path']

      begin
        @version = Gem::Version.new(@name.split(' ')[0])
      rescue
        @version = Installer::MINIMUM_VERSION
      end
    end

    def to_s
      "Xcode #{version} -- #{url}"
    end

    def ==(other)
      date_modified == other.date_modified && name == other.name && path == other.path && \
        url == other.url && version == other.version
    end

    def self.new_prerelease(version, url, release_notes_path)
      new('name' => version,
          'dateModified' => Time.now.to_i,
          'files' => [{ 'remotePath' => url.split('=').last }],
          'release_notes_path' => release_notes_path)
    end
  end
end
