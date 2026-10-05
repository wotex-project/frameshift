defmodule FrameshiftPlatform.AtomFilterFixture do
  @moduledoc false

  use Ash.Resource,
    domain: FrameshiftPlatform.AtomDomainFixture,
    data_layer: Ash.DataLayer.Ets

  ets do
    private? true
  end

  actions do
    defaults [:read, create: :*]
  end

  attributes do
    uuid_primary_key :id
    attribute :value, :atom, public?: true, constraints: [unsafe_to_atom?: true]
  end
end

defmodule FrameshiftPlatform.AtomDomainFixture do
  @moduledoc false

  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource FrameshiftPlatform.AtomFilterFixture
  end
end
