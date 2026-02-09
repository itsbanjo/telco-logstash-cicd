#!/usr/bin/env ruby
# ============================================================================
# TelcoNZ SNMP Pipeline Configuration Generator
# ============================================================================
# This script reads the master telconz-snmp-config.yml and generates
# individual Logstash pipeline configurations for each device group.
#
# Usage:
#   ruby generate-snmp-pipelines.rb [options]
#
# Options:
#   --config PATH    Path to master config (default: ./telconz-snmp-config.yml)
#   --output DIR     Output directory (default: ./pipelines/snmp/)
#   --template PATH  ERB template path (default: ./templates/snmp-pipeline-template.conf.erb)
#   --dry-run        Show what would be generated without writing files
#   --validate       Validate config without generating
#
# ============================================================================

require 'yaml'
require 'erb'
require 'fileutils'
require 'optparse'

# Default paths
DEFAULT_CONFIG = '/etc/logstash/config/telconz-snmp-config.yml'
DEFAULT_OUTPUT = '/etc/logstash/pipelines/snmp'
DEFAULT_TEMPLATE = '/etc/logstash/templates/snmp-pipeline-template.conf.erb'

class SNMPPipelineGenerator
  def initialize(config_path, output_dir, template_path, options = {})
    @config_path = config_path
    @output_dir = output_dir
    @template_path = template_path
    @dry_run = options[:dry_run] || false
    @verbose = options[:verbose] || false
    @config = nil
  end

  def load_config
    unless File.exist?(@config_path)
      error "Configuration file not found: #{@config_path}"
      exit 1
    end

    begin
      @config = YAML.load_file(@config_path)
      log "Loaded configuration: #{@config['total_devices']} devices in #{@config['pipelines'].keys.length} pipelines"
    rescue => e
      error "Failed to parse YAML: #{e.message}"
      exit 1
    end
  end

  def validate_config
    errors = []
    warnings = []

    # Check required top-level keys
    %w[version defaults pipelines].each do |key|
      errors << "Missing required key: #{key}" unless @config[key]
    end

    # Validate each pipeline
    @config['pipelines']&.each do |name, pipeline|
      unless pipeline['devices'] && pipeline['devices'].is_a?(Array)
        errors << "Pipeline '#{name}' has no devices array"
        next
      end

      if pipeline['devices'].empty?
        warnings << "Pipeline '#{name}' has no devices"
      end

      # Validate device entries
      pipeline['devices'].each_with_index do |device, idx|
        %w[hostname ip region tier type domain vendor model].each do |field|
          unless device[field]
            errors << "Pipeline '#{name}' device #{idx} missing field: #{field}"
          end
        end

        # Validate IP format
        if device['ip'] && !device['ip'].match?(/^\d+\.\d+\.\d+\.\d+$/)
          errors << "Pipeline '#{name}' device #{idx} has invalid IP: #{device['ip']}"
        end
      end

      # Check interval
      unless pipeline['interval'].is_a?(Integer) && pipeline['interval'] > 0
        errors << "Pipeline '#{name}' has invalid interval: #{pipeline['interval']}"
      end
    end

    # Report results
    warnings.each { |w| warn "WARNING: #{w}" }
    
    if errors.any?
      errors.each { |e| error "ERROR: #{e}" }
      return false
    end

    log "Configuration validated successfully"
    true
  end

  def load_template
    unless File.exist?(@template_path)
      error "Template file not found: #{@template_path}"
      exit 1
    end

    begin
      @template = ERB.new(File.read(@template_path), trim_mode: '-')
      log "Loaded template: #{@template_path}"
    rescue => e
      error "Failed to load template: #{e.message}"
      exit 1
    end
  end

  def generate_pipelines
    unless @config && @template
      error "Config or template not loaded"
      exit 1
    end

    # Create output directory
    unless @dry_run
      FileUtils.mkdir_p(@output_dir)
      log "Output directory: #{@output_dir}"
    end

    generated = []
    
    @config['pipelines'].each do |pipeline_name, pipeline_config|
      output_file = File.join(@output_dir, "snmp-#{pipeline_name}.conf")
      
      log "Generating: #{output_file} (#{pipeline_config['device_count']} devices)"

      begin
        # Render template
        content = @template.result_with_hash(
          pipeline_name: pipeline_name,
          pipeline_config: pipeline_config,
          defaults: @config['defaults']
        )

        if @dry_run
          log "  [DRY RUN] Would write #{content.length} bytes"
        else
          # Backup existing file
          if File.exist?(output_file)
            backup = "#{output_file}.backup.#{Time.now.strftime('%Y%m%d_%H%M%S')}"
            FileUtils.cp(output_file, backup)
            log "  Backed up existing config to: #{backup}"
          end

          # Write new config
          File.write(output_file, content)
          log "  Written: #{output_file} (#{content.length} bytes)"
        end

        generated << {
          name: pipeline_name,
          file: output_file,
          devices: pipeline_config['device_count'],
          interval: pipeline_config['interval']
        }
      rescue => e
        error "Failed to generate #{pipeline_name}: #{e.message}"
        error e.backtrace.first(5).join("\n") if @verbose
      end
    end

    # Generate pipelines.yml
    generate_pipelines_yml(generated) unless @dry_run

    # Print summary
    puts "\n" + "=" * 60
    puts "GENERATION SUMMARY"
    puts "=" * 60
    puts "Total pipelines: #{generated.length}"
    puts "Total devices:   #{generated.sum { |p| p[:devices] }}"
    puts "\nPipeline breakdown:"
    generated.each do |p|
      puts "  #{p[:name].ljust(15)} #{p[:devices].to_s.rjust(5)} devices @ #{p[:interval]}s interval"
    end
    puts "=" * 60
  end

  def generate_pipelines_yml(pipelines)
    pipelines_yml_path = File.join(File.dirname(@output_dir), 'pipelines.yml')
    
    content = pipelines.map do |p|
      {
        'pipeline.id' => "snmp-#{p[:name]}",
        'path.config' => p[:file],
        'pipeline.workers' => @config['pipelines'][p[:name]]['workers'] || 1,
        'pipeline.batch.size' => 250
      }
    end

    File.write(pipelines_yml_path, content.to_yaml)
    log "Generated pipelines.yml: #{pipelines_yml_path}"
  end

  private

  def log(msg)
    puts "[INFO] #{msg}"
  end

  def warn(msg)
    puts "[WARN] #{msg}"
  end

  def error(msg)
    puts "[ERROR] #{msg}"
  end
end

# Extend ERB for named parameters
class ERB
  def result_with_hash(hash)
    b = binding
    hash.each { |k, v| b.local_variable_set(k, v) }
    result(b)
  end
end

# Main execution
if __FILE__ == $0
  options = {
    config: DEFAULT_CONFIG,
    output: DEFAULT_OUTPUT,
    template: DEFAULT_TEMPLATE,
    dry_run: false,
    validate_only: false,
    verbose: false
  }

  OptionParser.new do |opts|
    opts.banner = "Usage: #{$0} [options]"

    opts.on("-c", "--config PATH", "Path to master config YAML") do |v|
      options[:config] = v
    end

    opts.on("-o", "--output DIR", "Output directory for pipeline configs") do |v|
      options[:output] = v
    end

    opts.on("-t", "--template PATH", "Path to ERB template") do |v|
      options[:template] = v
    end

    opts.on("-n", "--dry-run", "Show what would be generated without writing") do
      options[:dry_run] = true
    end

    opts.on("-V", "--validate", "Validate config only, don't generate") do
      options[:validate_only] = true
    end

    opts.on("-v", "--verbose", "Verbose output") do
      options[:verbose] = true
    end

    opts.on("-h", "--help", "Show this help") do
      puts opts
      exit
    end
  end.parse!

  generator = SNMPPipelineGenerator.new(
    options[:config],
    options[:output],
    options[:template],
    dry_run: options[:dry_run],
    verbose: options[:verbose]
  )

  generator.load_config
  
  unless generator.validate_config
    exit 1
  end

  unless options[:validate_only]
    generator.load_template
    generator.generate_pipelines
  end
end
