# frozen_string_literal: true

require "spec_helper"
require "dependabot/dependency"
require "dependabot/dependency_file"
require "dependabot/composer/update_checker"
require_common_spec "update_checkers/shared_examples_for_update_checkers"

RSpec.describe Dependabot::Composer::UpdateChecker do
  it_behaves_like "an update checker"

  let(:checker) do
    described_class.new(
      dependency: dependency,
      dependency_files: files,
      credentials: credentials,
      ignored_versions: ignored_versions,
      security_advisories: security_advisories
    )
  end

  let(:dependency) do
    Dependabot::Dependency.new(
      name: dependency_name,
      version: dependency_version,
      requirements: requirements,
      package_manager: "composer"
    )
  end
  let(:ignored_versions) { [] }
  let(:security_advisories) { [] }
  let(:dependency_name) { "monolog/monolog" }
  let(:dependency_version) { "1.0.1" }
  let(:requirements) do
    [{ file: "composer.json", requirement: "1.0.*", groups: [], source: nil }]
  end
  let(:credentials) do
    [{
      "type" => "git_source",
      "host" => "github.com",
      "username" => "x-access-token",
      "password" => "token"
    }]
  end
  let(:files) { [composer_file, lockfile] }
  let(:composer_file) do
    Dependabot::DependencyFile.new(
      content: fixture("composer_files", manifest_fixture_name),
      name: "composer.json"
    )
  end
  let(:lockfile) do
    Dependabot::DependencyFile.new(
      content: fixture("lockfiles", lockfile_fixture_name),
      name: "composer.lock"
    )
  end
  let(:manifest_fixture_name) { "exact_version" }
  let(:lockfile_fixture_name) { "exact_version" }

  before do
    sanitized_name = dependency_name.downcase.gsub("/", "--")
    fixture = fixture("packagist_responses", "#{sanitized_name}.json")
    url = "https://packagist.org/p/#{dependency_name.downcase}.json"
    stub_request(:get, url).to_return(status: 200, body: fixture)
  end

  describe "#latest_version" do
    subject { checker.latest_version }

    let(:packagist_url) { "https://packagist.org/p/monolog/monolog.json" }
    let(:packagist_response) { fixture("packagist_response.json") }

    before do
      stub_request(:get, packagist_url).
        to_return(status: 200, body: packagist_response)
      allow(checker).to receive(:latest_resolvable_version).
        and_return(Gem::Version.new("1.17.0"))
    end

    it { is_expected.to eq(Gem::Version.new("1.22.1")) }

    context "when the user is ignoring the latest version" do
      let(:ignored_versions) { [">= 1.22.0.a, < 1.23"] }
      it { is_expected.to eq(Gem::Version.new("1.21.0")) }
    end

    context "when packagist returns an empty array" do
      before do
        stub_request(:get, packagist_url).
          to_return(status: 200, body: '{"packages":[]}')
        allow(checker).to receive(:latest_resolvable_version).
          and_return(Gem::Version.new("1.17.0"))
      end

      it { is_expected.to eq(Gem::Version.new("1.17.0")) }
    end

    context "with a path source" do
      let(:files) { [composer_file, lockfile, path_dep] }
      let(:manifest_fixture_name) { "path_source" }
      let(:lockfile_fixture_name) { "path_source" }
      let(:path_dep) do
        Dependabot::DependencyFile.new(
          name: "components/path_dep/composer.json",
          content: fixture("composer_files", "path_dep")
        )
      end
      before do
        stub_request(:get, "https://packagist.org/p/path_dep/path_dep.json").
          to_return(status: 404)
      end

      context "that is not the dependency we're checking" do
        it { is_expected.to eq(Gem::Version.new("1.22.1")) }
      end

      context "that is the dependency we're checking" do
        let(:dependency_name) { "path_dep/path_dep" }
        let(:current_version) { "1.0.1" }
        let(:requirements) do
          [{
            requirement: "1.0.*",
            file: "composer.json",
            groups: ["runtime"],
            source: { type: "path" }
          }]
        end

        it { is_expected.to be_nil }
      end
    end
  end

  describe "#latest_resolvable_version" do
    subject(:latest_resolvable_version) { checker.latest_resolvable_version }

    it "returns a non-normalized version, following semver" do
      expect(subject.segments.count).to eq(3)
    end

    it { is_expected.to be >= Gem::Version.new("1.22.0") }

    context "when the user is ignoring the latest version" do
      let(:ignored_versions) { [">= 1.22.0.a, < 3.0"] }
      it { is_expected.to eq(Gem::Version.new("1.21.0")) }
    end

    context "without a lockfile" do
      let(:files) { [composer_file] }
      it { is_expected.to be >= Gem::Version.new("1.22.0") }

      context "when there are conflicts at the version specified" do
        let(:manifest_fixture_name) { "conflicts" }
        let(:dependency_name) { "phpdocumentor/reflection-docblock" }
        let(:dependency_version) { nil }
        let(:requirements) do
          [{
            file: "composer.json",
            requirement: "^4.3",
            groups: [],
            source: nil
          }]
        end
        it { is_expected.to be >= Gem::Version.new("4.3.0") }
      end

      context "when an old version of PHP is specified" do
        let(:manifest_fixture_name) { "old_php_specified" }
        let(:dependency_name) { "illuminate/support" }
        let(:dependency_version) { "5.2.7" }
        let(:requirements) do
          [{
            file: "composer.json",
            requirement: "^5.2.0",
            groups: ["runtime"],
            source: nil
          }]
        end

        it { is_expected.to be >= Gem::Version.new("5.2.45") }

        context "as a platform requirement" do
          let(:manifest_fixture_name) { "old_php_platform" }
          it { is_expected.to eq(Gem::Version.new("5.4.36")) }

          context "and an extension is specified that we don't have" do
            let(:manifest_fixture_name) { "missing_extension" }

            it "pretends the missing extension is there" do
              expect(latest_resolvable_version).
                to eq(Dependabot::Composer::Version.new("5.4.36"))
            end
          end

          context "but the platform requirement only specifies an extension" do
            let(:manifest_fixture_name) { "bad_php" }

            it { is_expected.to eq(Gem::Version.new("5.4.36")) }
          end
        end
      end

      context "when an odd version of PHP is specified" do
        let(:manifest_fixture_name) { "odd_php_specified" }
        let(:dependency_name) { "illuminate/support" }
        let(:dependency_version) { "5.2.7" }
        let(:requirements) do
          [{
            file: "composer.json",
            requirement: "^5.2.0",
            groups: ["runtime"],
            source: nil
          }]
        end

        it { is_expected.to be >= Gem::Version.new("5.2.45") }
      end
    end

    context "with a dev dependency" do
      let(:manifest_fixture_name) { "development_dependencies" }
      let(:lockfile_fixture_name) { "development_dependencies" }
      it { is_expected.to be >= Gem::Version.new("1.22.0") }
    end

    context "with a path source" do
      let(:files) { [composer_file, lockfile, path_dep] }
      let(:manifest_fixture_name) { "path_source" }
      let(:lockfile_fixture_name) { "path_source" }
      let(:path_dep) do
        Dependabot::DependencyFile.new(
          name: "components/path_dep/composer.json",
          content: fixture("composer_files", "path_dep")
        )
      end
      before do
        stub_request(:get, "https://packagist.org/p/path_dep/path_dep.json").
          to_return(status: 404)
      end

      context "that is not the dependency we're checking" do
        it { is_expected.to be >= Gem::Version.new("1.22.0") }
      end

      context "that is the dependency we're checking" do
        let(:dependency_name) { "path_dep/path_dep" }
        let(:current_version) { "1.0.1" }
        let(:requirements) do
          [{
            requirement: "1.0.*",
            file: "composer.json",
            groups: ["runtime"],
            source: { type: "path" }
          }]
        end

        it { is_expected.to be_nil }
      end
    end

    context "with a private registry" do
      let(:manifest_fixture_name) { "private_registry" }
      let(:lockfile_fixture_name) { "private_registry" }
      before { `composer clear-cache --quiet` }

      let(:dependency_name) { "dependabot/dummy-pkg-a" }
      let(:dependency_version) { nil }
      let(:requirements) do
        [{
          file: "composer.json",
          requirement: "*",
          groups: [],
          source: nil
        }]
      end

      before do
        url = "https://php.fury.io/dependabot-throwaway/packages.json"
        stub_request(:get, url).
          to_return(status: 200, body: fixture("gemfury_response.json"))
      end

      context "with good credentials" do
        let(:credentials) do
          [{
            "type" => "git_source",
            "host" => "github.com",
            "username" => "x-access-token",
            "password" => "token"
          }, {
            "type" => "composer_repository",
            "registry" => "php.fury.io",
            "username" => "yFu9PBmw1HxNjFB818TW", # Throwaway account
            "password" => ""
          }]
        end

        it { is_expected.to be >= Gem::Version.new("2.2.0") }
      end

      context "with bad credentials" do
        let(:credentials) do
          [{
            "type" => "git_source",
            "host" => "github.com",
            "username" => "x-access-token",
            "password" => "token"
          }, {
            "type" => "composer_repository",
            "registry" => "php.fury.io",
            "username" => "bad",
            "password" => ""
          }]
        end

        it "raises a helpful error message" do
          expect { checker.latest_resolvable_version }.
            to raise_error do |error|
              expect(error).
                to be_a(Dependabot::PrivateSourceAuthenticationFailure)
              expect(error.source).to eq("php.fury.io")
            end
        end
      end

      context "with no credentials" do
        let(:credentials) do
          [{
            "type" => "git_source",
            "host" => "github.com",
            "username" => "x-access-token",
            "password" => "token"
          }]
        end

        it "raises a helpful error message" do
          expect { checker.latest_resolvable_version }.
            to raise_error do |error|
              expect(error).
                to be_a(Dependabot::PrivateSourceAuthenticationFailure)
              expect(error.source).to eq("php.fury.io")
            end
        end
      end
    end

    context "with a replaced dependency" do
      let(:manifest_fixture_name) { "replaced_dependency" }
      let(:lockfile_fixture_name) { "replaced_dependency" }
      let(:dependency_name) { "illuminate/console" }
      let(:dependency_version) { nil }
      let(:requirements) do
        [{
          file: "composer.json",
          requirement: "5.5.*",
          groups: [],
          source: nil
        }]
      end
      it { is_expected.to be_nil }
    end

    context "with a replaced direct dependency" do
      let(:manifest_fixture_name) { "replaced_direct_dependency" }
      let(:files) { [composer_file] }
      let(:dependency_name) { "neos/flow" }
      let(:dependency_version) { nil }
      let(:requirements) do
        [{
          file: "composer.json",
          requirement: "*",
          groups: [],
          source: nil
        }]
      end
      it { is_expected.to be_nil }
    end

    context "with a PEAR dependency" do
      let(:manifest_fixture_name) { "pear" }
      let(:lockfile_fixture_name) { "pear" }
      let(:dependency_name) { "pear-pear.horde.org/Horde_Date" }
      let(:dependency_version) { "2.4.1" }
      let(:requirements) do
        [{
          file: "composer.json",
          requirement: "^2.4.0@stable",
          groups: [],
          source: nil
        }]
      end

      it "is between 2.0.0 and 3.0.0" do
        expect(latest_resolvable_version).to be < Gem::Version.new("3.0.0")
        expect(latest_resolvable_version).to be > Gem::Version.new("2.0.0")
      end
    end

    context "with a version conflict at the latest version" do
      let(:manifest_fixture_name) { "version_conflict_at_latest" }
      let(:lockfile_fixture_name) { "version_conflict_at_latest" }
      let(:dependency_name) { "doctrine/dbal" }
      let(:dependency_version) { "2.1.5" }
      let(:requirements) do
        [{
          file: "composer.json",
          requirement: "1.0.*",
          groups: [],
          source: nil
        }]
      end
      let(:ignored_versions) { [">= 2.8.0"] }

      it "is the highest resolvable version" do
        expect(latest_resolvable_version).to eq(Gem::Version.new("2.1.7"))
      end

      context "where the blocking dependency is a git dependency" do
        let(:manifest_fixture_name) { "git_source_conflict_at_latest" }
        let(:lockfile_fixture_name) { "git_source_conflict_at_latest" }

        pending "is the highest resolvable version" do
          # It would be nice if this worked, but currently Composer ignores
          # resolvability requirements for git dependencies.
          expect(latest_resolvable_version).to eq(Gem::Version.new("2.1.7"))
        end
      end
    end

    context "with a version conflict in the current files" do
      let(:files) { [composer_file, lockfile] }
      let(:manifest_fixture_name) { "version_conflict" }
      let(:dependency_name) { "monolog/monolog" }
      let(:dependency_version) { "2.1.5" }
      let(:requirements) do
        [{
          file: "composer.json",
          requirement: "1.0.*",
          groups: [],
          source: nil
        }]
      end

      it { is_expected.to be_nil }

      context "and there is no lockfile" do
        let(:files) { [composer_file] }

        it "raises a resolvability error" do
          expect { latest_resolvable_version }.
            to raise_error(Dependabot::DependencyFileNotResolvable)
        end
      end
    end

    context "with an update that can't resolve" do
      let(:files) { [composer_file, lockfile] }
      let(:manifest_fixture_name) { "version_conflict_on_update" }
      let(:lockfile_fixture_name) { "version_conflict_on_update" }
      let(:dependency_name) { "longman/telegram-bot" }
      let(:dependency_version) { "2.1.5" }
      let(:requirements) do
        [{
          file: "composer.json",
          requirement: "1.0.*",
          groups: [],
          source: nil
        }]
      end

      it { is_expected.to be_nil }

      context "and there is no lockfile" do
        let(:files) { [composer_file] }

        it { is_expected.to be_nil }

        context "and the conflict comes from a loose PHP version" do
          let(:manifest_fixture_name) { "version_conflict_library" }
          let(:files) { [composer_file] }

          it { is_expected.to be_nil }
        end
      end
    end

    context "with a dependency with a git source" do
      let(:manifest_fixture_name) { "git_source" }
      let(:lockfile_fixture_name) { "git_source" }
      it { is_expected.to be >= Gem::Version.new("1.22.1") }

      context "that is not the gem we're checking" do
        let(:dependency_name) { "symfony/polyfill-mbstring" }
        let(:dependency_version) { "1.0.1" }
        let(:requirements) do
          [{
            file: "composer.json",
            requirement: "1.0.*",
            groups: [],
            source: nil
          }]
        end

        it { is_expected.to be >= Gem::Version.new("1.3.0") }

        context "with a bad commit" do
          let(:lockfile_fixture_name) { "git_source_bad_commit" }

          # Alternatively, this could raise an error. Either behaviour would be
          # fine - the below is just what we get with Composer at the moment.
          it { is_expected.to be >= Gem::Version.new("1.3.0") }
        end

        context "with a git URL" do
          let(:manifest_fixture_name) { "git_source_git_url" }
          let(:lockfile_fixture_name) { "git_source_git_url" }

          it { is_expected.to be >= Gem::Version.new("1.3.0") }
        end

        context "that is unreachable" do
          let(:manifest_fixture_name) { "git_source_unreachable" }
          let(:lockfile_fixture_name) { "git_source_unreachable" }

          it "raises a helpful error" do
            expect { checker.latest_resolvable_version }.
              to raise_error do |error|
                expect(error).to be_a(Dependabot::GitDependenciesNotReachable)
                expect(error.dependency_urls).
                  to eq(["https://github.com/no-exist-sorry/monolog"])
              end
          end

          context "with a git URL" do
            let(:manifest_fixture_name) { "git_source_unreachable_git_url" }
            let(:lockfile_fixture_name) { "git_source_unreachable_git_url" }

            it "raises a helpful error" do
              expect { checker.latest_resolvable_version }.
                to raise_error do |error|
                  expect(error).to be_a(Dependabot::GitDependenciesNotReachable)
                  expect(error.dependency_urls).
                    to eq(["git@github.com:no-exist-sorry/monolog"])
                end
            end
          end
        end
      end
    end

    context "when an alternative source is specified" do
      let(:manifest_fixture_name) { "alternative_source" }
      let(:lockfile_fixture_name) { "alternative_source" }
      let(:dependency_name) { "wpackagist-plugin/acf-to-rest-api" }
      let(:dependency_version) { "2.2.1" }
      let(:requirements) do
        [{
          file: "composer.json",
          requirement: "*",
          groups: ["runtime"],
          source: nil
        }]
      end

      before do
        stub_request(:get, "https://wpackagist.org/packages.json").
          to_return(
            status: 200,
            body: fixture("wpackagist_response.json")
          )
      end

      it { is_expected.to be >= Gem::Version.new("3.0.2") }
    end

    context "when an autoload is specified" do
      let(:manifest_fixture_name) { "autoload" }
      let(:lockfile_fixture_name) { "autoload" }
      let(:dependency_name) { "illuminate/support" }
      let(:dependency_version) { "5.2.7" }
      let(:requirements) do
        [{
          file: "composer.json",
          requirement: "^5.2.0",
          groups: ["runtime"],
          source: nil
        }]
      end

      it { is_expected.to be >= Gem::Version.new("5.2.30") }
    end

    context "when a sub-dependency would block the update" do
      let(:manifest_fixture_name) { "subdependency_update_required" }
      let(:lockfile_fixture_name) { "subdependency_update_required" }
      let(:dependency_name) { "illuminate/support" }
      let(:dependency_version) { "5.2.0" }
      let(:requirements) do
        [{
          file: "composer.json",
          requirement: "^5.2.0",
          groups: ["runtime"],
          source: nil
        }]
      end

      # 5.5.0 series and up require an update to illuminate/contracts
      it { is_expected.to be >= Gem::Version.new("5.6.23") }
    end
  end

  describe "#preferred_resolvable_version" do
    subject { checker.preferred_resolvable_version }

    let(:ignored_versions) { [">= 1.22.0.a, < 3.0"] }
    it { is_expected.to eq(Gem::Version.new("1.21.0")) }

    context "with an insecure version" do
      let(:dependency_version) { "1.0.1" }
      let(:security_advisories) do
        [
          Dependabot::SecurityAdvisory.new(
            dependency_name: dependency_name,
            package_manager: "composer",
            vulnerable_versions: ["<= 1.15.0"]
          )
        ]
      end
      it { is_expected.to eq(Gem::Version.new("1.16.0")) }
    end
  end

  describe "#updated_requirements" do
    subject { checker.updated_requirements.first }

    let(:dependency) do
      Dependabot::Dependency.new(
        name: "monolog/monolog",
        version: "1.0.1",
        requirements: dependency_requirements,
        package_manager: "composer"
      )
    end
    let(:dependency_requirements) do
      [{
        file: "composer.json",
        requirement: "1.0.*",
        groups: [],
        source: nil
      }]
    end

    before do
      allow(checker).
        to receive(:latest_resolvable_version).
        and_return(Gem::Version.new("1.6.0"))
    end

    it "delegates to the RequirementsUpdater" do
      expect(described_class::RequirementsUpdater).
        to receive(:new).
        with(
          requirements: dependency_requirements,
          latest_resolvable_version: "1.6.0",
          update_strategy: :bump_versions_if_necessary
        ).
        and_call_original
      expect(checker.updated_requirements).
        to eq(
          [{
            file: "composer.json",
            requirement: "1.6.*",
            groups: [],
            source: nil
          }]
        )
    end

    context "with an insecure version" do
      let(:security_advisories) do
        [
          Dependabot::SecurityAdvisory.new(
            dependency_name: dependency_name,
            package_manager: "composer",
            vulnerable_versions: ["<= 1.15.0"]
          )
        ]
      end

      before do
        allow(checker).
          to receive(:lowest_resolvable_security_fix_version).
          and_return(Gem::Version.new("1.5.0"))
      end

      it "delegates to the RequirementsUpdater" do
        expect(described_class::RequirementsUpdater).
          to receive(:new).
          with(
            requirements: dependency_requirements,
            latest_resolvable_version: "1.5.0",
            update_strategy: :bump_versions_if_necessary
          ).
          and_call_original
        expect(checker.updated_requirements).
          to eq(
            [{
              file: "composer.json",
              requirement: "1.5.*",
              groups: [],
              source: nil
            }]
          )
      end
    end
  end
end
