require 'rake/testtask'

# Dir["lib/tasks/**/*.rake"].sort.each { |ext| load ext }

Rake::TestTask.new(:test) do |t|
  t.libs << "test"
  t.libs << "lib"
  t.test_files = FileList['test/**/*_test.rb']
end

task :default => :test