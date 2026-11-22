require "io/console"

namespace :identity do
  desc "Interactively create an organization owner. Run: bin/rails identity:bootstrap"
  task bootstrap: :environment do
    abort "Interactive terminal required" unless $stdin.tty?

    print "Organization name: "
    name = $stdin.gets.to_s.strip
    print "Organization slug: "
    slug = $stdin.gets.to_s.strip
    print "Owner email: "
    email = $stdin.gets.to_s.strip
    print "Owner password: "
    password = $stdin.noecho(&:gets).to_s.chomp
    puts

    ActiveRecord::Base.transaction do
      organization = Organization.create!(name: name, slug: slug)
      user = User.create!(email: email, password: password, password_confirmation: password)
      Membership.create!(organization: organization, user: user, role: "owner")
      puts "Created organization #{organization.slug} and owner #{user.email}"
    end
  end

  desc "Issue credential. Set ORG, NAME, PROVIDER, PERMISSIONS, REPOSITORIES, ENVIRONMENTS."
  task issue: :environment do
    organization = Organization.find_by!(slug: ENV.fetch("ORG"))
    permissions = ENV.fetch("PERMISSIONS").split(",").map(&:strip)
    repositories = ENV.fetch("REPOSITORIES", "").split(",").map(&:strip).reject(&:empty?)
    environments = ENV.fetch("ENVIRONMENTS", "").split(",").map(&:strip).reject(&:empty?)

    credential, token = IntegrationCredential.issue!(
      organization: organization,
      name: ENV.fetch("NAME"), provider: ENV.fetch("PROVIDER"),
      permissions: permissions, repository_scopes: repositories,
      environment_scopes: environments
    )
    puts "Created credential ##{credential.id} for #{organization.slug}."
    puts "Store this token securely; it will not be displayed again:"
    puts token
  end

  desc "Revoke credential. Set ORG and CREDENTIAL_ID."
  task revoke: :environment do
    organization = Organization.find_by!(slug: ENV.fetch("ORG"))
    credential = organization.integration_credentials.find(ENV.fetch("CREDENTIAL_ID"))
    credential.revoke!
    puts "Credential ##{credential.id} revoked."
  end
end
