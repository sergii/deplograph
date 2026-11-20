class BuildArtifact < ApplicationRecord
  belongs_to :build
  belongs_to :artifact
end
