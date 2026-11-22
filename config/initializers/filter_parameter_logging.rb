Rails.application.config.filter_parameters += %i[
  password token secret key authorization access_token refresh_token
  sbom raw_document
]
