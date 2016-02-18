###
#
# This provides methods to generate documentation for a module.
#
###

require 'octokit'
require 'nokogiri'
require 'redcarpet'
require 'net/http'
require 'erb'

module Redcarpet
  module Render
    class MsfMdHTML < Redcarpet::Render::HTML
      def block_code(code, language)
        "<pre>" \
          "<code>#{code}</code>" \
        "</pre>"
      end
    end
  end
end


module Msf
  module Util
    module DocumentGenerator

      class DocumentNormalizer

        CSS_BASE_PATH              = File.expand_path(File.join(Msf::Config.data_directory, 'markdown_doc', 'markdown.css'))
        TEMPLATE_PATH              = File.expand_path(File.join(Msf::Config.data_directory, 'markdown_doc', 'default_template.erb'))
        BES_DEMO_TEMPLATE          = File.expand_path(File.join(Msf::Config.data_directory, 'markdown_doc', 'bes_demo_template.erb'))
        HTTPSERVER_DEMO_TEMPLATE   = File.expand_path(File.join(Msf::Config.data_directory, 'markdown_doc', 'httpserver_demo_template.erb'))
        GENERIC_DEMO_TEMPLATE      = File.expand_path(File.join(Msf::Config.data_directory, 'markdown_doc', 'generic_demo_template.erb'))
        LOCALEXPLOIT_DEMO_TEMPLATE = File.expand_path(File.join(Msf::Config.data_directory, 'markdown_doc', 'localexploit_demo_template.erb'))
        POST_DEMO_TEMPLATE         = File.expand_path(File.join(Msf::Config.data_directory, 'markdown_doc', 'post_demo_template.erb'))
        PAYLOAD_TEMPLATE           = File.expand_path(File.join(Msf::Config.data_directory, 'markdown_doc', 'payload_demo_template.erb'))
        AUXILIARY_SCANNER_TEMPLATE = File.expand_path(File.join(Msf::Config.data_directory, 'markdown_doc', 'auxiliary_scanner_template.erb'))

        def get_md_content(items)
          @md_template ||= lambda {
            template = ''
            File.open(TEMPLATE_PATH, 'rb') { |f| template = f.read }
            return template
          }.call
          md_to_html(ERB.new(@md_template).result(binding()))
        end

        private

        def load_css
          @css ||= lambda {
            data = ''
            File.open(CSS_BASE_PATH, 'rb') { |f| data = f.read }
            return data
          }.call
        end

        def md_to_html(md)
          r = Redcarpet::Markdown.new(Redcarpet::Render::MsfMdHTML, fenced_code_blocks: true) 
          %Q|
          <html>
          <head>
          <style>
          #{load_css}
          </style>
          </head>
          <body>
          #{r.render(md)}
          </body>
          </html>
          |
        end

        def normalize_pull_requests(pull_requests)
          if pull_requests.kind_of?(PullRequestFinder::Exception)
            error = Rex::Text.html_encode(pull_requests.message)
            return error
          end

          formatted_pr = []

          pull_requests.each_pair do |number, pr|
            formatted_pr << "* <a href=\"https://github.com/rapid7/metasploit-framework/pull/#{number}\">##{number}</a> - #{pr[:title]}"
          end

          formatted_pr * "\n"
        end

        def normalize_options(mod_options)
          required_options = []

          mod_options.each_pair do |name, props|
            if props.required && props.default.nil?
              required_options << "* #{name} - #{props.desc}"
            end
          end

          required_options * "\n"
        end

        def normalize_description(description)
          Rex::Text.wordwrap(Rex::Text.compress(description))
        end

        def normalize_authors(authors)
          if authors.kind_of?(Array)
            authors.collect { |a| "* #{Rex::Text.html_encode(a)}" } * "\n"
          else
            Rex::Text.html_encode(authors)
          end
        end

        def normalize_targets(targets)
          targets.collect { |c| "* #{c.name}" } * "\n"
        end

        def normalize_references(refs)
          refs.collect { |r| "* <a href=\"#{r}\">#{r}</a>" } * "\n"
        end

        def normalize_platforms(platforms)
          if platforms.kind_of?(Array)
            platforms.collect { |p| "* #{p}" } * "\n"
          else
            platforms
          end
        end

        def normalize_rank(rank)
          "[#{Msf::RankingName[rank].capitalize}](https://github.com/rapid7/metasploit-framework/wiki/Exploit-Ranking)"
        end

        def load_template(mod, path)
          data = ''
          File.open(path, 'rb') { |f| data = f.read }
          ERB.new(data).result(binding())
        end

        def normalize_demo_output(mod)
          if mod.kind_of?(Msf::Exploit::Remote::BrowserExploitServer)
            load_template(mod, BES_DEMO_TEMPLATE)
          elsif mod.kind_of?(Msf::Exploit::Remote::HttpServer)
            load_template(mod, HTTPSERVER_DEMO_TEMPLATE)
          elsif mod.kind_of?(Msf::Exploit::Local)
            load_template(mod, LOCALEXPLOIT_DEMO_TEMPLATE)
          elsif mod.kind_of?(Msf::Post)
            load_template(mod, POST_DEMO_TEMPLATE)
          elsif mod.kind_of?(Msf::Payload)
            load_template(mod, PAYLOAD_TEMPLATE)
          elsif mod.kind_of?(Msf::Auxiliary::Scanner)
            load_template(mod, AUXILIARY_SCANNER_TEMPLATE)
          else
            load_template(mod, GENERIC_DEMO_TEMPLATE)
          end
        end

      end

      class PullRequestFinder
        class Exception < RuntimeError; end

        MANUAL_BASE_PATH = File.expand_path(File.join(Msf::Config.module_directory, '..', 'documentation', 'modules' ))

        attr_accessor :git_client
        attr_accessor :repository
        attr_accessor :branch
        attr_accessor :owner
        attr_accessor :git_access_token

        def initialize
          unless ENV.has_key?('GITHUB_OAUTH_TOKEN')
            raise PullRequestFinder::Exception, 'GITHUB_OAUTH_TOKEN environment variable not set.'
          end

          self.owner            = 'rapid7'
          self.repository       = "#{owner}/metasploit-framework"
          self.branch           = 'master'
          self.git_access_token = ENV['GITHUB_OAUTH_TOKEN']
          self.git_client       = Octokit::Client.new(access_token: git_access_token)
        end

        def search(mod)
          file_name = get_normalized_module_name(mod)
          commits = get_commits_from_file(file_name)
          get_pull_requests_from_commits(commits)
        end

        private

        def get_normalized_module_name(mod)
          source_fname = mod.method(:initialize).source_location.first
          source_fname.scan(/(modules.+)/).flatten.first || ''
        end

        def get_commits_from_file(path)
          commits = git_client.commits(repository, branch, path: path)
          if commits.empty?
            # Possibly the path is wrong.
            raise PullRequestFinder::Exception, 'No commits found.'
          end

          commits
        end

        def get_author(commit)
          if commit.author
            return commit.author[:login].to_s
          end

          ''
        end

        def is_author_blacklisted?(commit)
          ['tabassassin'].include?(get_author(commit))
        end

        def get_pull_requests_from_commits(commits)
          pull_requests = {}

          commits.each do |commit|
            next if is_author_blacklisted?(commit)

            pr = get_pull_request_from_commit(commit)
            unless pr.empty?
              pull_requests[pr[:number]] = pr
            end
          end

          pull_requests
        end

        def get_pull_request_from_commit(commit)
          sha = commit.sha
          url = URI.parse("https://github.com/#{repository}/branch_commits/#{sha}")
          cli = Net::HTTP.new(url.host, url.port)
          cli.use_ssl = true
          req = Net::HTTP::Get.new(url.request_uri)
          res = cli.request(req)
          n = Nokogiri::HTML(res.body)
          found_pr_link = n.at('li[@class="pull-request"]//a')

          # If there is no PR associated with this commit, it's probably from the SVN days.
          return {} unless found_pr_link

          href  = found_pr_link.attributes['href'].text
          title = found_pr_link.attributes['title'].text

          # Filter out all the pull requests that do not belong to rapid7.
          # If this happens, it's probably because the PR was submitted to somebody's fork.
          return {} unless /^\/#{owner}\// === href

          { number: href.scan(/\d+$/).flatten.first, title: title }
        end

      end

      def self.spawn_module_document(mod)
        md = get_module_document(mod)
        f = Rex::Quickfile.new(["#{mod.shortname}_doc", '.html'])
        f.write(md)
        f.close
        Rex::Compat.open_webrtc_browser("file://#{f.path}")
      end

      def self.get_module_document(mod)
        manual_path = File.join(PullRequestFinder::MANUAL_BASE_PATH, "#{mod.fullname}.md")

        if File.exists?(manual_path)
          Rex::Compat.open_webrtc_browser("file://#{manual_path}")
        else
          begin
            pr_finder = PullRequestFinder.new
            pr = pr_finder.search(mod)
          rescue PullRequestFinder::Exception => e
            # This is a little weird, I guess, because the normalizer must handle two different
            # data types.
            pr = e
          end
          n = DocumentNormalizer.new
          items = {
            mod_description:   mod.description,
            mod_authors:       mod.send(:module_info)['Author'],
            mod_fullname:      mod.fullname,
            mod_name:          mod.name,
            mod_pull_requests: pr,
            mod_refs:          mod.references,
            mod_rank:          mod.rank,
            mod_platforms:     mod.send(:module_info)['Platform'],
            mod_options:       mod.options,
            mod_demo:          mod
          }

          if mod.respond_to?(:targets) && mod.targets
            items[:mod_targets] = mod.targets
          end

          n.get_md_content(items)
        end
      end

    end
  end
end
