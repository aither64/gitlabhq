require 'spec_helper'

describe Gitlab::Git::GitlabProjects do
  after do
    TestEnv.clean_test_path
  end

  let(:project) { create(:project, :repository) }

  if $VERBOSE
    let(:logger) { Logger.new(STDOUT) }
  else
    let(:logger) { double('logger').as_null_object }
  end

  let(:tmp_repos_path) { TestEnv.repos_path }
  let(:repo_name) { project.disk_path + '.git' }
  let(:tmp_repo_path) { File.join(tmp_repos_path, repo_name) }
  let(:gl_projects) { build_gitlab_projects(tmp_repos_path, repo_name) }

  describe '#initialize' do
    it { expect(gl_projects.shard_path).to eq(tmp_repos_path) }
    it { expect(gl_projects.repository_relative_path).to eq(repo_name) }
    it { expect(gl_projects.repository_absolute_path).to eq(File.join(tmp_repos_path, repo_name)) }
    it { expect(gl_projects.logger).to eq(logger) }
  end

  describe '#mv_project' do
    let(:new_repo_path) { File.join(tmp_repos_path, 'repo.git') }

    it 'moves a repo directory' do
      expect(File.exist?(tmp_repo_path)).to be_truthy

      message = "Moving repository from <#{tmp_repo_path}> to <#{new_repo_path}>."
      expect(logger).to receive(:info).with(message)

      expect(gl_projects.mv_project('repo.git')).to be_truthy

      expect(File.exist?(tmp_repo_path)).to be_falsy
      expect(File.exist?(new_repo_path)).to be_truthy
    end

    it "fails if the source path doesn't exist" do
      expected_source_path = File.join(tmp_repos_path, 'bad-src.git')
      expect(logger).to receive(:error).with("mv-project failed: source path <#{expected_source_path}> does not exist.")

      result = build_gitlab_projects(tmp_repos_path, 'bad-src.git').mv_project('repo.git')
      expect(result).to be_falsy
    end

    it 'fails if the destination path already exists' do
      FileUtils.mkdir_p(File.join(tmp_repos_path, 'already-exists.git'))

      expected_distination_path = File.join(tmp_repos_path, 'already-exists.git')
      message = "mv-project failed: destination path <#{expected_distination_path}> already exists."
      expect(logger).to receive(:error).with(message)

      expect(gl_projects.mv_project('already-exists.git')).to be_falsy
    end
  end

  describe '#rm_project' do
    it 'removes a repo directory' do
      expect(File.exist?(tmp_repo_path)).to be_truthy
      expect(logger).to receive(:info).with("Removing repository <#{tmp_repo_path}>.")

      expect(gl_projects.rm_project).to be_truthy

      expect(File.exist?(tmp_repo_path)).to be_falsy
    end
  end

  describe '#push_branches' do
    let(:remote_name) { 'remote-name' }
    let(:branch_name) { 'master' }
    let(:cmd) { %W(git push -- #{remote_name} #{branch_name}) }
    let(:force) { false }

    subject { gl_projects.push_branches(remote_name, 600, force, [branch_name]) }

    it 'executes the command' do
      stub_spawn(cmd, 600, tmp_repo_path, success: true)

      is_expected.to be_truthy
    end

    it 'fails' do
      stub_spawn(cmd, 600, tmp_repo_path, success: false)

      is_expected.to be_falsy
    end

    context 'with --force' do
      let(:cmd) { %W(git push --force -- #{remote_name} #{branch_name}) }
      let(:force) { true }

      it 'executes the command' do
        stub_spawn(cmd, 600, tmp_repo_path, success: true)

        is_expected.to be_truthy
      end
    end
  end

  describe '#fetch_remote' do
    let(:remote_name) { 'remote-name' }
    let(:branch_name) { 'master' }
    let(:force) { false }
    let(:tags) { true }
    let(:args) { { force: force, tags: tags }.merge(extra_args) }
    let(:extra_args) { {} }
    let(:cmd) { %W(git fetch #{remote_name} --prune --quiet --tags) }

    subject { gl_projects.fetch_remote(remote_name, 600, args) }

    def stub_tempfile(name, filename, opts = {})
      chmod = opts.delete(:chmod)
      file = StringIO.new

      allow(file).to receive(:close!)
      allow(file).to receive(:path).and_return(name)

      expect(Tempfile).to receive(:new).with(filename).and_return(file)
      expect(file).to receive(:chmod).with(chmod) if chmod

      file
    end

    context 'with default args' do
      it 'executes the command' do
        stub_spawn(cmd, 600, tmp_repo_path, {}, success: true)

        is_expected.to be_truthy
      end

      it 'fails' do
        stub_spawn(cmd, 600, tmp_repo_path, {}, success: false)

        is_expected.to be_falsy
      end
    end

    context 'with --force' do
      let(:force) { true }
      let(:cmd) { %W(git fetch #{remote_name} --prune --quiet --force --tags) }

      it 'executes the command with forced option' do
        stub_spawn(cmd, 600, tmp_repo_path, {}, success: true)

        is_expected.to be_truthy
      end
    end

    context 'with --no-tags' do
      let(:tags) { false }
      let(:cmd) { %W(git fetch #{remote_name} --prune --quiet --no-tags) }

      it 'executes the command' do
        stub_spawn(cmd, 600, tmp_repo_path, {}, success: true)

        is_expected.to be_truthy
      end
    end

    describe 'with an SSH key' do
      let(:extra_args) { { ssh_key: 'SSH KEY' } }

      it 'sets GIT_SSH to a custom script' do
        script = stub_tempfile('scriptFile', 'gitlab-shell-ssh-wrapper', chmod: 0o755)
        key = stub_tempfile('/tmp files/keyFile', 'gitlab-shell-key-file', chmod: 0o400)

        stub_spawn(cmd, 600, tmp_repo_path, { 'GIT_SSH' => 'scriptFile' }, success: true)

        is_expected.to be_truthy

        expect(script.string).to eq("#!/bin/sh\nexec ssh '-oIdentityFile=\"/tmp files/keyFile\"' '-oIdentitiesOnly=\"yes\"' \"$@\"")
        expect(key.string).to eq('SSH KEY')
      end
    end

    describe 'with known_hosts data' do
      let(:extra_args) { { known_hosts: 'KNOWN HOSTS' } }

      it 'sets GIT_SSH to a custom script' do
        script = stub_tempfile('scriptFile', 'gitlab-shell-ssh-wrapper', chmod: 0o755)
        key = stub_tempfile('/tmp files/knownHosts', 'gitlab-shell-known-hosts', chmod: 0o400)

        stub_spawn(cmd, 600, tmp_repo_path, { 'GIT_SSH' => 'scriptFile' }, success: true)

        is_expected.to be_truthy

        expect(script.string).to eq("#!/bin/sh\nexec ssh '-oStrictHostKeyChecking=\"yes\"' '-oUserKnownHostsFile=\"/tmp files/knownHosts\"' \"$@\"")
        expect(key.string).to eq('KNOWN HOSTS')
      end
    end
  end

  describe '#import_project' do
    let(:project) { create(:project) }
    let(:import_url) { TestEnv.factory_repo_path_bare }
    let(:cmd) { %W(git clone --bare -- #{import_url} #{tmp_repo_path}) }
    let(:timeout) { 600 }

    subject { gl_projects.import_project(import_url, timeout) }

    context 'success import' do
      it 'imports a repo' do
        expect(File.exist?(File.join(tmp_repo_path, 'HEAD'))).to be_falsy

        message = "Importing project from <#{import_url}> to <#{tmp_repo_path}>."
        expect(logger).to receive(:info).with(message)

        is_expected.to be_truthy

        expect(File.exist?(File.join(tmp_repo_path, 'HEAD'))).to be_truthy
      end
    end

    context 'already exists' do
      it "doesn't import" do
        FileUtils.mkdir_p(tmp_repo_path)

        is_expected.to be_falsy
      end
    end

    context 'timeout' do
      it 'does not import a repo' do
        stub_spawn_timeout(cmd, timeout, nil)

        message = "Importing project from <#{import_url}> to <#{tmp_repo_path}> failed."
        expect(logger).to receive(:error).with(message)

        is_expected.to be_falsy

        expect(gl_projects.output).to eq("Timed out\n")
        expect(File.exist?(File.join(tmp_repo_path, 'HEAD'))).to be_falsy
      end
    end
  end

  describe '#fork_repository' do
    let(:dest_repos_path) { tmp_repos_path }
    let(:dest_repo_name) { File.join('@hashed', 'aa', 'bb', 'xyz.git') }
    let(:dest_repo) { File.join(dest_repos_path, dest_repo_name) }
    let(:dest_namespace) { File.dirname(dest_repo) }

    subject { gl_projects.fork_repository(dest_repos_path, dest_repo_name) }

    before do
      FileUtils.mkdir_p(dest_repos_path)
    end

    after do
      FileUtils.rm_rf(dest_repos_path)
    end

    it 'forks the repository' do
      message = "Forking repository from <#{tmp_repo_path}> to <#{dest_repo}>."
      expect(logger).to receive(:info).with(message)

      is_expected.to be_truthy

      expect(File.exist?(dest_repo)).to be_truthy
      expect(File.exist?(File.join(dest_repo, 'hooks', 'pre-receive'))).to be_truthy
      expect(File.exist?(File.join(dest_repo, 'hooks', 'post-receive'))).to be_truthy
    end

    it 'does not fork if a project of the same name already exists' do
      # create a fake project at the intended destination
      FileUtils.mkdir_p(dest_repo)

      # trying to fork again should fail as the repo already exists
      message = "fork-repository failed: destination repository <#{dest_repo}> already exists."
      expect(logger).to receive(:error).with(message)

      is_expected.to be_falsy
    end

    context 'different storages' do
      let(:dest_repos_path) { File.join(File.dirname(tmp_repos_path), 'alternative') }

      it 'forks the repo' do
        is_expected.to be_truthy

        expect(File.exist?(dest_repo)).to be_truthy
        expect(File.exist?(File.join(dest_repo, 'hooks', 'pre-receive'))).to be_truthy
        expect(File.exist?(File.join(dest_repo, 'hooks', 'post-receive'))).to be_truthy
      end
    end
  end

  def build_gitlab_projects(*args)
    described_class.new(
      *args,
      global_hooks_path: Gitlab.config.gitlab_shell.hooks_path,
      logger: logger
    )
  end

  def stub_spawn(*args, success: true)
    exitstatus = success ? 0 : nil
    expect(gl_projects).to receive(:popen_with_timeout).with(*args)
      .and_return(["output", exitstatus])
  end

  def stub_spawn_timeout(*args)
    expect(gl_projects).to receive(:popen_with_timeout).with(*args)
      .and_raise(Timeout::Error)
  end
end
