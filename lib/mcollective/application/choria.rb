module MCollective
  class Application::Choria < Application
    description "Orchastrator for Puppet Applications"

    option :environment,
           :arguments => ["--environment ENVIRONMENT"],
           :description => "The environment to run, defaults to production",
           :type => String

    def valid_commands
      methods.grep(/_command$/).map{|c| c.to_s.gsub("_command", "")}
    end

    def post_option_parser(configuration)
      if ARGV.length >= 1
        configuration[:command] = ARGV.shift
      else
        abort("Please specify a command, valid commands are: %s" % valid_commands.join(", "))
      end

      unless valid_commands.include?(configuration[:command])
        abort("Unknown command %s, valid commands are: %s" % [configuration[:command], valid_commands.join(", ")])
      end
    end

    def validate_configuration(configuration)
      configuration[:environment] ||= "production"

    end

    def choria
      @_choria ||= Util::Choria.new(configuration[:environment])
    end

    def confirm(msg)
      print("%s (y/n) " % msg)

      STDOUT.flush

      exit(1) unless STDIN.gets.strip.match(/^(?:y|yes)$/i)
    end

    def show_plan(env)
      puts("Puppet Site Plan for the %s Environment" % Util.colorize(:bold, env.environment))
      puts
      puts("%s applications on %s managed nodes:" % [Util.colorize(:bold, env.applications.size), Util.colorize(:bold, env.nodes.size)])
      puts
      env.applications.each do |app|
        puts("\t%s" % app)
      end
      puts
      puts("Node groups and run order:")

      env.each_node_group do |group|
        puts(Util.colorize(:green, "   ------------------------------------------------------------------"))

        group.each do |node|
          puts("\t%s" % Util.colorize(:bold, node))

          app_resources = env.node(node)[:application_resources].sort_by{|k,v| k}
          app_resources.each do |app, resources|
            puts("\t\t%s -> %s" % [app, resources.sort.join(", ")])
          end
          puts
        end
      end
    end

    def log(msg)
      puts("        %s: %s" % [Time.now, msg])
    end

    def green(msg)
      Util.colorize(:green, msg)
    end

    def bold(msg)
      Util.colorize(:bold, msg)
    end

    def red(msg)
      Util.colorize(:red, msg)
    end

    def client
      @client ||= rpcclient("puppet")
    end

    def run_nodes(nodes)
      log("Running Puppet on %s nodes" % bold(nodes.size))

      client.discover(:nodes => nodes)
      client.runonce
      wait_till_nodes_start(nodes)
    end

    def all_nodes_enabled?(nodes)
      log("Checking if %s nodes are enabled" % bold(nodes.size))

      client.discover(:nodes => nodes)
      client.status.map {|resp| resp.results[:data][:enabled]}.all?
    end

    def wait_till_nodes_start(nodes)
      client.discover(:nodes => nodes)

      20.times do |i|
        log("Waiting for %s nodes to start a run" % bold(nodes.size)) if i % 4 == 0

        break if client.status.map {|resp| resp.results[:data][:applying] }.all?
        sleep 5
      end
    end

    def wait_till_nodes_idle(nodes)
      client.discover(:nodes => nodes)

      20.times do |i|
        log("Waiting for %s nodes to become idle" % bold(nodes.size)) if i % 4 == 0

        break if client.status.map {|resp| resp.results[:data][:applying] }.none?
        sleep 5
      end
    end

    def failed_nodes(nodes)
      client.discover(:nodes => nodes)

      client.last_run_summary.select{|resp| resp.results[:data][:failed_resources] > 0}
    end

    def run_plan(env)
      gc = 1

      client.progress = false

      unless all_nodes_enabled?(env.nodes)
        abort(red("Not all nodes in the plan are enabled, cannot continue"))
      end

      env.each_node_group do |group|
        start_time = Time.now

        puts
        puts("Running node group %s with %s nodes" % [bold(gc), bold(group.size)])

        wait_till_nodes_idle(group)
        run_nodes(group)
        wait_till_nodes_idle(group)

        if !(failed = failed_nodes(group).empty?)
          puts("Puppet failed to run on %s / %s nodes, cannot continue" % [red(failed.size), red(group.size)])

          failed.each do |node|
            puts("\t%s" % bold(node))
          end

          exit(1)
        else
          elapsed = "%0.2f" % [Time.now - start_time]

          puts
          puts("Succesful run of %s nodes in group %s in %s seconds" % [green(group.size), bold(gc), bold(elapsed)])
        end

        gc += 1
      end
    end

    def plan_command
      show_plan(choria.puppet_environment)
    end

    def run_command
      env = choria.puppet_environment

      show_plan(env)

      confirm("Are you sure you wish to run this plan?")

      puts

      run_plan(env)
    end

    def main
      Util.loadclass("MCollective::Util::Choria")
      send("%s_command" % configuration[:command])
    end
  end
end