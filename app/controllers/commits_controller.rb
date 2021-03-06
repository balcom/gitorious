# encoding: utf-8
#--
#   Copyright (C) 2011 Gitorious AS
#   Copyright (C) 2009 Nokia Corporation and/or its subsidiary(-ies)
#   Copyright (C) 2008 Johan Sørensen <johan@johansorensen.com>
#   Copyright (C) 2008 David A. Cuadrado <krawek@gmail.com>
#   Copyright (C) 2008 Tor Arne Vestbø <tavestbo@trolltech.com>
#
#   This program is free software: you can redistribute it and/or modify
#   it under the terms of the GNU Affero General Public License as published by
#   the Free Software Foundation, either version 3 of the License, or
#   (at your option) any later version.
#
#   This program is distributed in the hope that it will be useful,
#   but WITHOUT ANY WARRANTY; without even the implied warranty of
#   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#   GNU Affero General Public License for more details.
#
#   You should have received a copy of the GNU Affero General Public License
#   along with this program.  If not, see <http://www.gnu.org/licenses/>.
#++

class CommitsController < ApplicationController
  before_filter :find_project_and_repository
  before_filter :check_repository_for_commits
  skip_before_filter :public_and_logged_in, :only => [:diffs]
  skip_before_filter :require_current_eula, :only => [:diffs]
  skip_after_filter :mark_flash_status, :only => [:diffs]
  renders_in_site_specific_context

  def index
    if params[:branch].blank?
      redirect_to_ref(@repository.head_candidate.name) and return
    end

    @git = @repository.git
    @ref, @path = branch_and_path(params[:branch], @git)

    head = get_head(@ref)
    return handle_unknown_ref if head.nil?

    if stale_conditional?(head.commit.id, head.commit.committed_date.utc)
      @root = Breadcrumb::Branch.new(head, @repository)
      @commits = @repository.cached_paginated_commits(@ref, params[:page])
      @atom_auto_discovery_url = project_repository_formatted_commits_feed_path(@project, @repository, params[:branch], :atom)
      respond_to do |format|
        format.html
      end
    end
  end

  def show
    @diffs = []
    @diffmode = params[:diffmode] == "sidebyside" ? "sidebyside" : "inline"
    @git = @repository.git
    @diffs_url = project_repository_commit_diffs_url(:project_id => params[:project_id],
                                                     :repository_id => params[:repository_id],
                                                     :id => params[:id])
    @comments_url = project_repository_commit_comments_url(:project_id => params[:project_id],
                                                           :repository_id => params[:repository_id],
                                                           :id => params[:id])

    unless @commit = @git.commit(params[:id])
      handle_missing_sha and return
    end

    @root = Breadcrumb::Commit.new(:repository => @repository, :id => @commit.id_abbrev)

    respond_to do |format|
      format.html

      format.diff do
        render(:text => commit_diffs.map { |d| d.diff }.join("\n"),
               :content_type => "text/plain")
      end

      format.patch do
        render :text => @commit.to_patch, :content_type => "text/plain"
      end
    end
  end

  def comments
    @comments = @repository.comments.find_all_by_sha1(params[:id], :include => :user)
    last_modified = @comments.size > 0 ? @comments.last.created_at.utc : Time.at(0)

    if stale_conditional?([params[:id], @comments.size], last_modified)
      @comment_count = @comments.length
      render :layout => !request.xhr?
    end
  end

  def diffs
    @comments = []
    @diffmode = params[:diffmode] == "sidebyside" ? "sidebyside" : "inline"
    @git = @repository.git

    unless @commit = @git.commit(params[:id])
      handle_missing_sha and return
    end

    @root = Breadcrumb::Commit.new(:repository => @repository, :id => @commit.id_abbrev)
    @diffs = commit_diffs
    @committer_user = User.find_by_email_with_aliases(@commit.committer.email)
    @author_user = User.find_by_email_with_aliases(@commit.author.email)
    headers["Cache-Control"] = "public, max-age=315360000"

    render :layout => !request.xhr?
  end

  def feed
    @git = @repository.git
    @ref = desplat_path(params[:branch])
    @commits = @repository.git.commits(@ref, 1)
    return if @commits.empty?
    expires_in 30.minutes
    if stale?(:etag => @commits.first.id, :last_modified => @commits.first.committed_date.utc)
      @commits += @repository.git.commits(@ref, 49, 1)
      respond_to do |format|
        format.atom
      end
    end
  end
  
  protected
    def handle_missing_sha
      flash[:error] = "No such SHA1 was found"
      redirect_to repo_owner_path(@repository, :project_repository_commits_path, @project, 
                      @repository)
    end
    
    def redirect_to_ref(ref)
      redirect_to repo_owner_path(@repository, :project_repository_commits_in_ref_path, 
                      @project, @repository, ref)
    end

    def commit_diffs
      @commit.parents.empty? ? [] : @commit.diffs
    end

    def get_head(ref)
      if h = @git.get_head(ref)
        return h
      end

      begin
        if commit = @git.commit(@ref)
          return Grit::Head.new(commit.id_abbrev, commit)
        end
      rescue Errno::EISDIR => err
      end

      nil
    end

    def handle_unknown_ref
      flash[:error] = "\"#{CGI.escapeHTML(@ref)}\" was not a valid ref, trying #{CGI.escapeHTML(@git.head.name)} instead"
      redirect_to_ref(@git.head.name)
    end
end
