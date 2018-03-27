require 'pdk/util'

module PDK
  module Util
    class PuppetVersion
      class << self
        extend Forwardable

        def_delegators :instance, :find_gem_for, :from_pe_version, :from_module_metadata

        attr_writer :instance

        def instance
          @instance ||= new
        end
      end

      def find_gem_for(version_str)
        ensure_semver_version!(version_str)
        version = Gem::Version.new(version_str)

        exact_requirement = Gem::Requirement.create(version)
        found_gem = find_gem(exact_requirement)
        return found_gem unless found_gem.nil?

        latest_requirement = Gem::Requirement.create("#{version.approximate_recommendation}.0")
        found_gem = find_gem(latest_requirement)
        unless found_gem.nil?
          PDK.logger.info _('Unable to find Puppet %{requested_version}, using %{found_version} instead') % {
            requested_version: version_str,
            found_version:     found_gem[:gem_version].version,
          }
          return found_gem
        end

        raise ArgumentError, _('Unable to find a Puppet version matching %{requirement}') % {
          requirement: latest_requirement,
        }
      end

      def from_pe_version(version_str)
        ensure_semver_version!(version_str)

        version = Gem::Version.new(version_str)
        gem_version = pe_version_map.find do |version_map|
          version_map[:requirement].satisfied_by?(version)
        end

        if gem_version.nil?
          raise ArgumentError, _('Unable to map Puppet Enterprise version %{pe_version} to a Puppet version') % {
            pe_version: version_str,
          }
        end

        PDK.logger.info _('Puppet Enterprise %{pe_version} maps to Puppet %{puppet_version}') % {
          pe_version:     version_str,
          puppet_version: gem_version[:gem_version],
        }
        find_gem_for(gem_version[:gem_version])
      end

      def from_module_metadata(metadata)
        msgs = {
          not_metadata:  _('Not a valid PDK::Module::Metadata object'),
          no_reqs:       _('Module metadata does not contain any requirements'),
          no_puppet_req: _('Module metadata does not contain a "puppet" requirement'),
          no_puppet_ver: _('"puppet" requirement in module metadata does not specify a "version_requirement"'),
        }

        raise ArgumentError, msgs[:not_metadata] unless metadata.is_a?(PDK::Module::Metadata)
        raise ArgumentError, msgs[:no_reqs] unless metadata.data.key?('requirements')

        metadata_requirement = metadata.data['requirements'].find do |r|
          r.key?('name') && r['name'] == 'puppet'
        end

        raise ArgumentError, msgs[:no_puppet_req] if metadata_requirement.nil?
        raise ArgumentError, msgs[:no_puppet_ver] unless metadata_requirement.key?('version_requirement')
        raise ArgumentError, msgs[:no_puppet_ver] if metadata_requirement['version_requirement'].empty?

        # Split combined requirements like ">= 4.7.0 < 6.0.0" into their
        # component requirements [">= 4.7.0", "< 6.0.0"]
        pattern = %r{#{Gem::Requirement::PATTERN_RAW}}
        requirement_strings = metadata_requirement['version_requirement'].scan(pattern).map do |req|
          req.compact.join(' ')
        end

        gem_requirement = Gem::Requirement.create(requirement_strings)
        find_gem(gem_requirement)
      end

      private

      def ensure_semver_version!(version_str)
        return if version_str =~ %r{\A\d+\.\d+\.\d+\Z}

        raise ArgumentError, _('%{version} is not a valid version number') % {
          version: version_str,
        }
      end

      def pe_version_map
        @pe_version_map ||= fetch_pe_version_map.map do |version_map|
          {
            requirement: requirement_from_forge_range(version_map['name']),
            gem_version: version_map['puppet'],
          }
        end
      end

      # TODO: Replace this with a cached forge lookup like we do for the task
      # metadata schema (PDK-828)
      def fetch_pe_version_map
        [
          { 'name' => '2017.3.x', 'puppet_range' => '5.3.x',  'puppet' => '5.3.2'  },
          { 'name' => '2017.2.x', 'puppet_range' => '4.10.x', 'puppet' => '4.10.1' },
          { 'name' => '2017.1.x', 'puppet_range' => '4.9.x',  'puppet' => '4.9.4'  },
          { 'name' => '2016.5.x', 'puppet_range' => '4.8.x',  'puppet' => '4.8.1'  },
          { 'name' => '2016.4.x', 'puppet_range' => '4.7.x',  'puppet' => '4.7.0'  },
          { 'name' => '2016.2.x', 'puppet_range' => '4.5.x',  'puppet' => '4.5.2'  },
          { 'name' => '2016.1.x', 'puppet_range' => '4.4.x',  'puppet' => '4.4.1'  },
          { 'name' => '2015.3.x', 'puppet_range' => '4.3.x',  'puppet' => '4.3.2'  },
          { 'name' => '2015.2.x', 'puppet_range' => '4.2.x',  'puppet' => '4.2.3'  },
        ]
      end

      def requirement_from_forge_range(range_str)
        range_str.gsub!(%r{\.x\Z}, '.0')
        Gem::Requirement.create("~> #{range_str}")
      end

      def rubygems_puppet_versions
        return @rubygems_puppet_versions unless @rubygems_puppet_versions.nil?

        fetcher = Gem::SpecFetcher.fetcher
        puppet_tuples = fetcher.detect(:released) do |spec_tuple|
          spec_tuple.name == 'puppet' && Gem::Platform.match(spec_tuple.platform)
        end
        puppet_versions = puppet_tuples.map { |name, _| name.version }.uniq
        @rubygems_puppet_versions = puppet_versions.sort { |a, b| b <=> a }
      end

      def find_gem(requirement)
        if PDK::Util.package_install?
          find_in_package_cache(requirement)
        else
          find_in_rubygems(requirement)
        end
      end

      def find_in_rubygems(requirement)
        version = rubygems_puppet_versions.find { |r| requirement.satisfied_by?(r) }
        version.nil? ? nil : { gem_version: version, ruby_version: PDK::Util::RubyVersion.default_ruby_version }
      end

      def find_in_package_cache(requirement)
        PDK::Util::RubyVersion.versions.each do |ruby_version, _|
          PDK::Util::RubyVersion.use(ruby_version)
          version = PDK::Util::RubyVersion.available_puppet_versions.find { |r| requirement.satisfied_by?(r) }
          return { gem_version: version, ruby_version: ruby_version } unless version.nil?
        end

        nil
      end
    end
  end
end
