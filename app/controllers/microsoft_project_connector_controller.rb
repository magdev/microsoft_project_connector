require 'json'

class MicrosoftProjectConnectorController < ApplicationController
  helper :microsoft_project_connector
  include MicrosoftProjectConnectorHelper
  helper :queries
  include QueriesHelper

  before_action :find_optional_project, :only => [:index, :query, :doQuery, :settings, :save]

  before_action :require_login, :except => [:test, :login]
  
  skip_before_action :check_if_login_required, :only => [:test]

  layout 'msc_base'

  def index
    client_version = params[:client_version]

    client_version = client_version.split('.').slice(0,2).join('.')

    unless available_client_versions.include? client_version
      @client_not_match = available_client_versions[available_client_versions.length - 1]
      return
    end

    if @project
      repeat_names_check = Hash.new
      repeat_names = []
      invalid_names = []

      @project.members.each do |member|
        id = member.user_id
        name = member.name
        if name.include? "\t"
          invalid_names << name
        end
        if repeat_names_check[name]
          if repeat_names_check[name] != id
            repeat_names << name
          end
        else
          repeat_names_check[name] = id
        end
      end

      unless invalid_names.blank?
        @error = l(:members_name_invalid, :names => invalid_names.join(', '))
        return
      end

      unless repeat_names.blank?
        @error = l(:members_name_repeat, :names => repeat_names.join(', '))
        return
      end

      unless params[:query_id]
        query = MicrosoftProjectConnectorQuery.where(:name => 'default', :project_id => @project.id).first
        if query
          params[:query_id] = query.id
        end
      end

      retrieve_query(MicrosoftProjectConnectorQuery)

      session['mspc_project_id'] = @project.id
    end
  end

  def view_query
    retrieve_query(MicrosoftProjectConnectorQuery)

    render :json => {
      :operatorLabels => Query.operators_labels,
      :operatorByType => Query.operators_by_filter_type,
      :availableFilters => @query.available_filters_as_json,
      :labelDayPlural => l(:label_day_plural)
    }
  end

  def settings    
    if params[:is_for_save]
      render :json => {
        :columns => available_redmine_columns.select{|c| c.present? },
        :members => @project.members.map{|m| {:id => m.user_id, :name => m.name}},
      }

      return
    end

    retrieve_query(MicrosoftProjectConnectorQuery)

    query = MicrosoftProjectConnectorQuery.where(:name => 'default', :project_id => @project.id).first

    if query
      query.filters = @query.filters
      query.user_id = User.current.id
      query.column_names = @query.column_names
      query.sort_criteria = @query.sort_criteria
      query.group_by = @query.group_by
      query.options = @query.options
    else
      @query.name = 'default'
      @query.user_id = User.current.id
      query = @query
    end

    query.save

    columns = available_redmine_columns.select{|column| column[:name] == 'id' || params[:c].include?(column[:name])}

    render :json => {
      :columns => columns.select{|c| c.present? },
      :members => @project.members.map{|m| {:id => m.user_id, :name => m.name}}
    }

  end

  def query
    retrieve_query(MicrosoftProjectConnectorQuery)

    if @query.valid?
      @offset, @limit = api_offset_and_limit
      @issue_count = @query.issue_count
      @issues = @query.issues(:offset => @offset, :limit => @limit)

      relations = IssueRelation.where(:issue_to_id => @issues.map(&:id)).where(:relation_type => [IssueRelation::TYPE_FINISH_FINISH, IssueRelation::TYPE_FINISH_START, IssueRelation::TYPE_START_START, IssueRelation::TYPE_START_FINISH])

      issues_data = @issues.map do |issue|
        issue_data = {:id => issue.id, :parent_id => issue.parent_id, :updated_on => issue.updated_on}
        @query.columns.each do |column|
          issue_data[column.name] = csv_content(column, issue)
        end

        issue_relations = relations.select{|relation| relation.issue_to_id == issue.id}.map{|relation| "#{relation_short_type_str(relation)}@#{relation.delay || 0}##{relation.issue_from_id}"}

        issue_data['relations'] = issue_relations.join(',') unless issue_relations.blank?

        issue_data
      end

      render :json => {
        :offset => @offset,
        :limit => @limit,
        :total_count => @issue_count,
        :issues => issues_data
      }
    else
      respond_to do |format|
        format.html { render :layout => !request.xhr? }
        format.any(:atom, :csv, :pdf) { head 422 }
        format.api { render_validation_errors(@query) }
      end
    end
  rescue ActiveRecord::RecordNotFound
    render_404
  end

  def save
    issues_hash = JSON.parse params[:data]

    custom_field_objects = CustomField.all().to_ary()
    custom_field_cache = {}
    errors = []
    new_issues_data = []
    
    if issues_hash.present? && !issues_hash.blank?
      guid_to_id = Hash.new
      depencencies = []
      exclude_removing_dependencies = []

      issues_hash.each do |issue_hash|
        issue_data = { :project_id => @project.id }

        custom_fields = []

        id = issue_hash['id'].to_i
        guid = issue_hash['guid']

        exclude_removing_dependency = {:to_id => id, :to_guid => guid, :from_ids => [], :from_guids => []}
        exclude_removing_dependencies.append exclude_removing_dependency

        issue_hash.each do |field_arr|
          if "relations" == field_arr[0]
            dependency_strs = field_arr[1]
            dependency_strs.split(',').each do |dependency_str|
              index1 = dependency_str.index '@'
              index2 = dependency_str.index '#'
              type = dependency_str[0...index1]
              lag = dependency_str[index1+1...index2]
              from_guid = dependency_str[index2+1..-1]
              index2 = from_guid.index '#'
              from_id = from_guid[index2+1..-1].to_i
              from_guid = from_guid[0...index2]

              if from_id > 0
                exclude_removing_dependency[:from_ids].append from_id
              else
                exclude_removing_dependency[:from_guids].append from_guid
              end
              depencencies << {:type => type, :lag => lag, :from_id => from_id, :from_guid => from_guid, :to_id => id, :to_guid => guid, :line_no => issue_hash['line_no']}
            end            
          else
            field_name = field_arr[0]
            if field_name.start_with? 'cf_'
              field_id = field_name[3..-1].to_i

              custom_fields << {:id => field_id, :value => parse_msp_custom_field_value(field_id, field_arr[1], custom_field_objects, custom_field_cache)}
            else
              parse_msp_field_value(field_name, field_arr[1], issue_data)
            end
          end
        end

        issue_data[:custom_fields] = custom_fields

        if id > 0
          issue_obj = Issue.where(:id => id).first
          unless issue_obj
            errors << [issue_data[:line_no], l(:issue_not_exists, :id => id)]	
          else
            issue_obj.init_journal(User.current)
            issue_obj.safe_attributes = issue_data
            if issue_hash['parent_id']
              issue_obj.parent_id = issue_hash['parent_id']
            else
              issue_obj.parent_id = issue_hash['parent_guid'] && guid_to_id[issue_hash['parent_guid']] ? guid_to_id[issue_hash['parent_guid']] : nil
            end

            if issue_obj.save
              new_issues_data.append :updated_on => format_time(issue_obj.updated_on), :last_updated_by => issue_obj.last_updated_by && issue_obj.last_updated_by.name, :guid => issue_data[:guid]
            else
              errors << [issue_data[:line_no], issue_obj.errors.full_messages.join('; ')]
            end
            
            guid_to_id[issue_data[:guid]] = issue_obj.id
          end

        else
          issue_obj = Issue.new
          issue_obj.author = User.current
          issue_obj.safe_attributes = issue_data
          if issue_data[:parent_id]
            issue_obj.parent_id = issue_data[:parent_id]
          elsif issue_data[:parent_guid]
            issue_obj.parent_id = guid_to_id[issue_data[:parent_guid]]
          end
          if issue_obj.save
            issue_obj[:id] = issue_obj.id
            new_issues_data.append :id => issue_obj.id, :created_on => format_time(issue_obj.created_on), :updated_on => format_time(issue_obj.updated_on), :author => issue_obj.author.name, :last_updated_by => issue_obj.author.name, :guid => issue_data[:guid]
            guid_to_id[issue_data[:guid]] = issue_obj.id 
          else
            errors << [issue_data[:line_no], issue_obj.errors.full_messages.join('; ')]
          end
        end
      end

      exclude_removing_dependencies.each do |removing_dependency|
        to_id = removing_dependency[:to_id]
        unless to_id > 0
          to_id = guid_to_id[removing_dependency[:to_guid]]
        end

        if to_id && to_id > 0
          from_ids = removing_dependency[:from_ids]
          removing_dependency[:from_guids].each do |guid|
            guid_id = guid_to_id[guid]
            if guid_id && guid_id > 0
              from_ids.append guid_id
            end
          end

          remove_relations(to_id, from_ids)
        end
      end

      depencencies.each do |dependency|
        if dependency[:from_id] > 0
          from_id = dependency[:from_id]
        else
          from_id = guid_to_id[dependency[:from_guid]]
        end

        if dependency[:to_id] > 0
          to_id = dependency[:to_id]
        else
          to_id = guid_to_id[dependency[:to_guid]]
        end

        if from_id && from_id > 0 && to_id && to_id > 0
          result = save_relation(from_id, to_id, dependency[:type], (dependency[:lag].to_i / 480.0).round)
          if result && result.errors && !result.errors.full_messages.empty?
            line_no = dependency[:line_no]

            error = errors.find{|e| e[0] == line_no}

            if error
              error[1] = "#{error[1]}; #{result.errors.full_messages.join('; ')}"
            else
              errors << [line_no, result.errors.full_messages.join('; ')]
            end
          end
        end
      end
    end

    render :json => {
      :new_issues_data => new_issues_data,
      :errors => errors.sort {|a, b| a[0].to_i <=> b[0].to_i}
    }
  end

  def delete_issue
    id = params[:id]
    issue = Issue.find id

    error = ''
    if issue 
      unless issue.deletable?
        error = l(:not_authorized_to_delete)
      end
      issue.destroy
    end

    render :json => {
      :error => error
    }
  end

  def test
    render :plain => 'ok'
  end

  def find_optional_project
    @project = Project.where('id = ? or identifier=?', params[:project_id], params[:project_id]).first unless params[:project_id].blank?
    @project = Project.find(session['mspc_project_id']) unless @project || session['mspc_project_id'].blank?
    #allowed = User.current.allowed_to?({:controller => params[:controller], :action => params[:action]}, @project, :global => true)
    #allowed ? true : deny_access
  rescue ActiveRecord::RecordNotFound
    render_404
  end
end
