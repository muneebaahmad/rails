# frozen_string_literal: true

require "action_view/dependency_tracker"

module ActionView
  class Digestor
    @@digest_mutex = Mutex.new

    module PerExecutionDigestCacheExpiry
      def self.before(target)
        ActionView::LookupContext::DetailsKey.clear
      end
    end

    class << self
      # Supported options:
      #
      # * <tt>name</tt>   - Template name
      # * <tt>finder</tt>  - An instance of <tt>ActionView::LookupContext</tt>
      # * <tt>dependencies</tt>  - An array of dependent views
      def digest(name:, format:, finder:, dependencies: nil)
        if dependencies.nil? || dependencies.empty?
          cache_key = "#{name}.#{format}"
        else
          cache_key = [ name, format, dependencies ].flatten.compact.join(".")
        end

        # this is a correctly done double-checked locking idiom
        # (Concurrent::Map's lookups have volatile semantics)
        finder.digest_cache[cache_key] || @@digest_mutex.synchronize do
          finder.digest_cache.fetch(cache_key) do # re-check under lock
            partial = name.include?("/_")
            root = tree(name, finder, partial)
            dependencies.each do |injected_dep|
              root.children << Injected.new(injected_dep, nil, nil)
            end if dependencies
            finder.digest_cache[cache_key] = root.digest(finder)
          end
        end
      end

      def logger
        ActionView::Base.logger || NullLogger
      end

      # Create a dependency tree for template named +name+.
      def tree(name, finder, partial = false, seen = {})
        logical_name = name.gsub(%r|/_|, "/")

        if template = find_template(finder, logical_name, [], partial, [])
          if node = seen[template.identifier] # handle cycles in the tree
            node
          else
            node = seen[template.identifier] = Node.create(name, logical_name, template, partial)

            deps = DependencyTracker.find_dependencies(name, template, finder.view_paths)
            deps.uniq { |n| n.gsub(%r|/_|, "/") }.each do |dep_file|
              node.children << tree(dep_file, finder, true, seen)
            end
            node
          end
        else
          unless name.include?("#") # Dynamic template partial names can never be tracked
            logger.error "  Couldn't find template for digesting: #{name}"
          end

          seen[name] ||= Missing.new(name, logical_name, nil)
        end
      end

      private
        def find_template(finder, name, prefixes, partial, keys)
          finder.disable_cache do
            finder.find_all(name, prefixes, partial, keys).first
          end
        end
    end

    class Node
      attr_reader :name, :logical_name, :template, :children

      def self.create(name, logical_name, template, partial)
        klass = partial ? Partial : Node
        klass.new(name, logical_name, template, [])
      end

      def initialize(name, logical_name, template, children = [])
        @name         = name
        @logical_name = logical_name
        @template     = template
        @children     = children
      end

      def digest(finder, stack = [])
        ActiveSupport::Digest.hexdigest("#{template.source}-#{dependency_digest(finder, stack)}")
      end

      def dependency_digest(finder, stack)
        children.map do |node|
          if stack.include?(node)
            false
          else
            finder.digest_cache[node.name] ||= begin
                                                 stack.push node
                                                 node.digest(finder, stack).tap { stack.pop }
                                               end
          end
        end.join("-")
      end

      def to_dep_map
        children.any? ? { name => children.map(&:to_dep_map) } : name
      end
    end

    class Partial < Node; end

    class Missing < Node
      def digest(finder, _ = []) "" end
    end

    class Injected < Node
      def digest(finder, _ = []) name end
    end

    class NullLogger
      def self.debug(_); end
      def self.error(_); end
    end
  end
end
