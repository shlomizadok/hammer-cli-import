#
# Copyright (c) 2014 Red Hat Inc.
#
# This file is part of hammer-cli-import.
#
# hammer-cli-import is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# hammer-cli-import is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with hammer-cli-import.  If not, see <http://www.gnu.org/licenses/>.
#

# Modules to help with imports. To be used as Extend/Import on classes that inherit
# from module HammerCLIImport::BaseCommand.
module ImportTools
  module Repository
    module Extend
      def add_repo_options
        option ['--synchronize'], :flag, 'Synchronize imported repositories', :default => false
        option ['--wait'], :flag, 'Wait for repository synchronization to finish', :default => false

        validate_options do
          option(:option_synchronize).required if option(:option_wait).exist?
        end
      end
    end

    module Include
      def repo_synced?(repo)
        raise ArgumentError, 'nil is not a valid repository' if repo.nil?

        info = lookup_entity(:repositories, repo['id'], true)
        return false unless info['sync_state'] == 'finished'
        Time.parse(info['last_sync']) > Time.parse(info['updated_at'])
      end

      # TODO: Shall be removed and in its place will come sync_repo2
      def sync_repo(repo)
        return unless option_synchronize?
        task = api_call(:repositories, :sync, {:id => repo['id']})
        puts 'Sync started!'
        return unless option_wait?
        wait_for_task task['id']
      end

      # TODO: This shall replace sync_repo
      def sync_repo2(repo)
        task = api_call(:repositories, :sync, {:id => repo['id']})
        puts 'Sync started!'
        task['id']
      rescue
        uuid = workaround_1116063 repo['id']
        puts 'Sync already running!'
        uuid
      end

      # TODO: Add logic to handle state
      # when there is sync already running
      def with_synced_repo(repo, &block)
        # So we can not give empty block
        if block_given?
          action = block
        else
          action = proc {}
        end

        if repo_synced?(repo)
          action.call
        else
          uuid = sync_repo2 repo
          postpone_till([uuid], &action) if option_wait?
        end
      end

      private

      # When BZ 1116063 get fixed, this might
      # be simplified using either
      # > api_call(:repositories, :show, {'id' => 1})
      # or maybe with
      # > api_call(:sync, :index, {:repository_id => 1})
      def workaround_1116063(repo_id)
        res = api_call :foreman_tasks, :bulk_search, \
                       :searches => [{:type => :resource, :resource_type => 'Katello::Repository', :resource_id => repo_id}]

        res.first['results'] \
          .select { |x| x['result'] != 'error' } \
          .sort_by { |x| Time.parse(x['started_at']) } \
          .last['id']
      end
    end
  end

  module Task
    module Include
      # [uuid] -> [uuid]
      def filter_finished_tasks(uuids)
        ret = []
        get_tasks_statuses(uuids).each do |uuid, stat|
          ret << uuid if stat['state'] == 'stopped'
        end
        ret
      end

      private

      # [uuid] -> {uuid: task_status}
      def get_tasks_statuses(uuids)
        searches = uuids.collect { |uuid| {:type => :task, :task_id => uuid} }
        ret = api_call :foreman_tasks, :bulk_search, {:searches => searches}
        statuses = {}
        ret.each do |status_result|
          status_result['results'].each do |task_info|
            statuses[task_info['id']] = task_info
          end
        end
        statuses
      end
    end
  end

  module ContentView
    module Include
      def publish_content_view(id)
        api_call :content_views, :publish, {:id => id}
      end

      # use entity_type as parameter to be able to re-use the method for
      # :content_views, :ak_content_views, :redhat_content_views, ...
      def delete_content_view(cv_id, entity_type = :content_views)
        raise "delete_content_view with #{entity_type}" unless map_target_entity[entity_type] == :content_views

        content_view = get_cache(entity_type)[cv_id]

        cv_version_ids = content_view['versions'].collect { |v| v['id'] }

        task = mapped_api_call(
          entity_type,
          :remove,
          {
            :id => content_view['id'],
            :content_view_version_ids => cv_version_ids
          })

        wait_for_task(task['id'], 1, 0)

        delete_entity_by_import_id(entity_type, content_view['id'])
      end
    end
  end
end
# vim: autoindent tabstop=2 shiftwidth=2 expandtab softtabstop=2 filetype=ruby
