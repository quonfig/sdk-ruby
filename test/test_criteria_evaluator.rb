# frozen_string_literal: true

require 'test_helper'
require 'timecop'

class TestCriteriaEvaluator < Minitest::Test
  PROJECT_ENV_ID = 1
  TEST_ENV_ID = 2
  KEY = 'the-key'
  DEFAULT_VALUE = 'default_value'
  DESIRED_VALUE = 'desired_value'
  WRONG_ENV_VALUE = 'wrong_env_value'

  DEFAULT_VALUE_CONFIG = PrefabProto::ConfigValue.new(string: DEFAULT_VALUE)
  DESIRED_VALUE_CONFIG = PrefabProto::ConfigValue.new(string: DESIRED_VALUE)

  TRUE_CONFIG = PrefabProto::ConfigValue.new(bool: true)
  FALSE_CONFIG = PrefabProto::ConfigValue.new(bool: false)

  DEFAULT_ROW = PrefabProto::ConfigRow.new(
    values: [
      PrefabProto::ConditionalValue.new(value: DEFAULT_VALUE_CONFIG)
    ]
  )

  def setup
    super
    @base_client = FakeBaseClient.new
  end

  def test_always_true
    config = PrefabProto::Config.new(
      id: 123,
      key: KEY,
      config_type: PrefabProto::ConfigType::CONFIG,
      rows: [
        DEFAULT_ROW,
        PrefabProto::ConfigRow.new(
          project_env_id: PROJECT_ENV_ID,
          values: [
            PrefabProto::ConditionalValue.new(
              criteria: [PrefabProto::Criterion.new(operator: PrefabProto::Criterion::CriterionOperator::ALWAYS_TRUE)],
              value: DESIRED_VALUE_CONFIG
            )
          ]
        )
      ]
    )

    evaluator = Quonfig::CriteriaEvaluator.new(config, project_env_id: PROJECT_ENV_ID, resolver: nil, base_client: @base_client, namespace: nil)

    assert_equal DESIRED_VALUE, evaluator.evaluate(context({})).unwrapped_value
  end

  def test_nested_props_in
    config = PrefabProto::Config.new(
      key: KEY,
      rows: [
        DEFAULT_ROW,
        PrefabProto::ConfigRow.new(
          project_env_id: PROJECT_ENV_ID,
          values: [
            PrefabProto::ConditionalValue.new(
              criteria: [
                PrefabProto::Criterion.new(
                  operator: PrefabProto::Criterion::CriterionOperator::PROP_IS_ONE_OF,
                  value_to_match: string_list(%w[ok fine]),
                  property_name: 'user.key'
                )
              ],
              value: DESIRED_VALUE_CONFIG
            )
          ]
        )
      ]
    )

    evaluator = Quonfig::CriteriaEvaluator.new(config, project_env_id: PROJECT_ENV_ID, resolver: nil, base_client: @base_client,
                                                      namespace: nil)

    assert_equal DEFAULT_VALUE, evaluator.evaluate(context({})).unwrapped_value
    assert_equal DEFAULT_VALUE, evaluator.evaluate(context({ user: { key: 'wrong' } })).unwrapped_value
    assert_equal DESIRED_VALUE, evaluator.evaluate(context({ user: { key: 'ok' } })).unwrapped_value
  end

  def test_nested_props_not_in
    config = PrefabProto::Config.new(
      key: KEY,
      rows: [
        DEFAULT_ROW,
        PrefabProto::ConfigRow.new(
          project_env_id: PROJECT_ENV_ID,
          values: [
            PrefabProto::ConditionalValue.new(
              criteria: [
                PrefabProto::Criterion.new(
                  operator: PrefabProto::Criterion::CriterionOperator::PROP_IS_NOT_ONE_OF,
                  value_to_match: string_list(%w[wrong bad]),
                  property_name: 'user.key'
                )
              ],
              value: DESIRED_VALUE_CONFIG
            )
          ]
        )
      ]
    )

    evaluator = Quonfig::CriteriaEvaluator.new(config, project_env_id: PROJECT_ENV_ID, resolver: nil, base_client: @base_client,
                                                      namespace: nil)

    assert_equal DESIRED_VALUE, evaluator.evaluate(context({})).unwrapped_value
    assert_equal DESIRED_VALUE, evaluator.evaluate(context({ user: { key: 'ok' } })).unwrapped_value
    assert_equal DEFAULT_VALUE, evaluator.evaluate(context({ user: { key: 'wrong' } })).unwrapped_value
  end

  def test_prop_is_one_of
    config = PrefabProto::Config.new(
      key: KEY,
      rows: [
        PrefabProto::ConfigRow.new(
          project_env_id: PROJECT_ENV_ID,
          values: [
            PrefabProto::ConditionalValue.new(
              criteria: [
                PrefabProto::Criterion.new(
                  operator: PrefabProto::Criterion::CriterionOperator::PROP_IS_ONE_OF,
                  value_to_match: string_list(['hotmail.com', 'gmail.com']),
                  property_name: 'user.email_suffix'
                )
              ],
              value: DESIRED_VALUE_CONFIG
            )
          ]
        ),
        DEFAULT_ROW
      ]
    )

    evaluator = Quonfig::CriteriaEvaluator.new(config, project_env_id: PROJECT_ENV_ID, resolver: nil, base_client: @base_client,
                                                      namespace: nil)

    assert_equal DEFAULT_VALUE, evaluator.evaluate(context({})).unwrapped_value
    assert_equal DEFAULT_VALUE, evaluator.evaluate(context(user: { email_suffix: 'prefab.cloud' })).unwrapped_value
    assert_equal DESIRED_VALUE, evaluator.evaluate(context(user: { email_suffix: 'hotmail.com' })).unwrapped_value
  end

  def test_prop_is_not_one_of
    config = PrefabProto::Config.new(
      key: KEY,
      rows: [
        DEFAULT_ROW,
        PrefabProto::ConfigRow.new(
          project_env_id: PROJECT_ENV_ID,
          values: [
            PrefabProto::ConditionalValue.new(
              criteria: [
                PrefabProto::Criterion.new(
                  operator: PrefabProto::Criterion::CriterionOperator::PROP_IS_NOT_ONE_OF,
                  value_to_match: string_list(['hotmail.com', 'gmail.com']),
                  property_name: 'user.email_suffix'
                )
              ],
              value: DESIRED_VALUE_CONFIG
            )
          ]
        )
      ]
    )

    evaluator = Quonfig::CriteriaEvaluator.new(config, project_env_id: PROJECT_ENV_ID, resolver: nil, base_client: @base_client,
                                                      namespace: nil)

    assert_equal DESIRED_VALUE, evaluator.evaluate(context({})).unwrapped_value
    assert_equal DESIRED_VALUE, evaluator.evaluate(context(user: { email_suffix: 'prefab.cloud' })).unwrapped_value
    assert_equal DEFAULT_VALUE, evaluator.evaluate(context(user: { email_suffix: 'hotmail.com' })).unwrapped_value
  end

  def test_prop_ends_with_one_of
    config = PrefabProto::Config.new(
      key: KEY,
      rows: [
        DEFAULT_ROW,
        PrefabProto::ConfigRow.new(
          project_env_id: PROJECT_ENV_ID,
          values: [
            PrefabProto::ConditionalValue.new(
              criteria: [
                PrefabProto::Criterion.new(
                  operator: PrefabProto::Criterion::CriterionOperator::PROP_ENDS_WITH_ONE_OF,
                  value_to_match: string_list(['hotmail.com', 'gmail.com']),
                  property_name: 'user.email'
                )
              ],
              value: DESIRED_VALUE_CONFIG
            )
          ]
        )
      ]
    )

    evaluator = Quonfig::CriteriaEvaluator.new(config, project_env_id: PROJECT_ENV_ID, resolver: nil, base_client: @base_client,
                                                      namespace: nil)

    assert_equal DEFAULT_VALUE, evaluator.evaluate(context({})).unwrapped_value
    assert_equal DEFAULT_VALUE, evaluator.evaluate(context(user: { email: 'example@prefab.cloud' })).unwrapped_value
    assert_equal DESIRED_VALUE, evaluator.evaluate(context(user: { email: 'example@hotmail.com' })).unwrapped_value
  end

  def test_prop_does_not_end_with_one_of
    config = PrefabProto::Config.new(
      key: KEY,
      rows: [
        DEFAULT_ROW,
        PrefabProto::ConfigRow.new(
          project_env_id: PROJECT_ENV_ID,
          values: [
            PrefabProto::ConditionalValue.new(
              criteria: [
                PrefabProto::Criterion.new(
                  operator: PrefabProto::Criterion::CriterionOperator::PROP_DOES_NOT_END_WITH_ONE_OF,
                  value_to_match: string_list(['hotmail.com', 'gmail.com']),
                  property_name: 'user.email'
                )
              ],
              value: DESIRED_VALUE_CONFIG
            )
          ]
        )
      ]
    )

    evaluator = Quonfig::CriteriaEvaluator.new(config, project_env_id: PROJECT_ENV_ID, resolver: nil, base_client: @base_client,
                                                      namespace: nil)

    assert_equal DESIRED_VALUE, evaluator.evaluate(context({})).unwrapped_value
    assert_equal DESIRED_VALUE, evaluator.evaluate(context(user: { email: 'example@prefab.cloud' })).unwrapped_value
    assert_equal DEFAULT_VALUE, evaluator.evaluate(context(user: { email: 'example@hotmail.com' })).unwrapped_value
  end

  def test_prop_starts_with_one_of
    config = PrefabProto::Config.new(
      key: KEY,
      rows: [
        DEFAULT_ROW,
        PrefabProto::ConfigRow.new(
          project_env_id: PROJECT_ENV_ID,
          values: [
            PrefabProto::ConditionalValue.new(
              criteria: [
                PrefabProto::Criterion.new(
                  operator: PrefabProto::Criterion::CriterionOperator::PROP_STARTS_WITH_ONE_OF,
                  value_to_match: string_list(['one', 'two']),
                  property_name: 'user.testProperty'
                )
              ],
              value: DESIRED_VALUE_CONFIG
            )
          ]
        )
      ]
    )

    evaluator = Quonfig::CriteriaEvaluator.new(config, project_env_id: PROJECT_ENV_ID, resolver: nil, base_client: @base_client,
                                              namespace: nil)

    assert_equal DEFAULT_VALUE, evaluator.evaluate(context({})).unwrapped_value
    assert_equal DEFAULT_VALUE, evaluator.evaluate(context(user: { testProperty: 'three dogs' })).unwrapped_value
    assert_equal DESIRED_VALUE, evaluator.evaluate(context(user: { testProperty: 'one tree' })).unwrapped_value
  end

  def test_prop_does_not_start_with_one_of
    config = PrefabProto::Config.new(
      key: KEY,
      rows: [
        DEFAULT_ROW,
        PrefabProto::ConfigRow.new(
          project_env_id: PROJECT_ENV_ID,
          values: [
            PrefabProto::ConditionalValue.new(
              criteria: [
                PrefabProto::Criterion.new(
                  operator: PrefabProto::Criterion::CriterionOperator::PROP_DOES_NOT_START_WITH_ONE_OF,
                  value_to_match: string_list(['one', 'two']),
                  property_name: 'user.testProperty'
                )
              ],
              value: DESIRED_VALUE_CONFIG
            )
          ]
        )
      ]
    )

    evaluator = Quonfig::CriteriaEvaluator.new(config, project_env_id: PROJECT_ENV_ID, resolver: nil, base_client: @base_client,
                                              namespace: nil)

    assert_equal DESIRED_VALUE, evaluator.evaluate(context({})).unwrapped_value
    assert_equal DESIRED_VALUE, evaluator.evaluate(context(user: { testProperty: 'three dogs' })).unwrapped_value
    assert_equal DEFAULT_VALUE, evaluator.evaluate(context(user: { testProperty: 'one tree' })).unwrapped_value
  end


  def test_prop_contains_one_of
    config = PrefabProto::Config.new(
      key: KEY,
      rows: [
        DEFAULT_ROW,
        PrefabProto::ConfigRow.new(
          project_env_id: PROJECT_ENV_ID,
          values: [
            PrefabProto::ConditionalValue.new(
              criteria: [
                PrefabProto::Criterion.new(
                  operator: PrefabProto::Criterion::CriterionOperator::PROP_CONTAINS_ONE_OF,
                  value_to_match: string_list(['one', 'two']),
                  property_name: 'user.testProperty'
                )
              ],
              value: DESIRED_VALUE_CONFIG
            )
          ]
        )
      ]
    )

    evaluator = Quonfig::CriteriaEvaluator.new(config, project_env_id: PROJECT_ENV_ID, resolver: nil, base_client: @base_client,
                                              namespace: nil)

    assert_equal DEFAULT_VALUE, evaluator.evaluate(context({})).unwrapped_value
    assert_equal DEFAULT_VALUE, evaluator.evaluate(context(user: { testProperty: 'three dogs' })).unwrapped_value
    assert_equal DESIRED_VALUE, evaluator.evaluate(context(user: { testProperty: 'see one tree' })).unwrapped_value
  end

  def test_prop_does_not_contain_one_of
    config = PrefabProto::Config.new(
      key: KEY,
      rows: [
        DEFAULT_ROW,
        PrefabProto::ConfigRow.new(
          project_env_id: PROJECT_ENV_ID,
          values: [
            PrefabProto::ConditionalValue.new(
              criteria: [
                PrefabProto::Criterion.new(
                  operator: PrefabProto::Criterion::CriterionOperator::PROP_DOES_NOT_CONTAIN_ONE_OF,
                  value_to_match: string_list(['one', 'two']),
                  property_name: 'user.testProperty'
                )
              ],
              value: DESIRED_VALUE_CONFIG
            )
          ]
        )
      ]
    )

    evaluator = Quonfig::CriteriaEvaluator.new(config, project_env_id: PROJECT_ENV_ID, resolver: nil, base_client: @base_client,
                                              namespace: nil)

    assert_equal DESIRED_VALUE, evaluator.evaluate(context({})).unwrapped_value
    assert_equal DESIRED_VALUE, evaluator.evaluate(context(user: { testProperty: 'three dogs' })).unwrapped_value
    assert_equal DEFAULT_VALUE, evaluator.evaluate(context(user: { testProperty: 'see one tree' })).unwrapped_value
  end

  def test_in_seg
    segment_key = 'segment_key'

    segment_config = PrefabProto::Config.new(
      config_type: PrefabProto::ConfigType::SEGMENT,
      key: segment_key,
      rows: [
        PrefabProto::ConfigRow.new(
          values: [
            PrefabProto::ConditionalValue.new(
              value: TRUE_CONFIG,
              criteria: [
                PrefabProto::Criterion.new(
                  operator: PrefabProto::Criterion::CriterionOperator::PROP_ENDS_WITH_ONE_OF,
                  value_to_match: string_list(['hotmail.com', 'gmail.com']),
                  property_name: 'user.email'
                )
              ]
            ),
            PrefabProto::ConditionalValue.new(value: FALSE_CONFIG)
          ]
        )
      ]
    )

    config = PrefabProto::Config.new(
      key: KEY,
      rows: [
        DEFAULT_ROW,

        PrefabProto::ConfigRow.new(
          project_env_id: PROJECT_ENV_ID,
          values: [
            PrefabProto::ConditionalValue.new(
              criteria: [
                PrefabProto::Criterion.new(
                  operator: PrefabProto::Criterion::CriterionOperator::IN_SEG,
                  value_to_match: PrefabProto::ConfigValue.new(string: segment_key)
                )
              ],
              value: DESIRED_VALUE_CONFIG
            )
          ]
        )
      ]
    )

    evaluator = Quonfig::CriteriaEvaluator.new(config, project_env_id: PROJECT_ENV_ID,
                                                      base_client: @base_client, namespace: nil,
                                                      resolver: resolver_fake({ segment_key => segment_config }))

    assert_equal DEFAULT_VALUE, evaluator.evaluate(context({})).unwrapped_value
    assert_equal DEFAULT_VALUE, evaluator.evaluate(context(user: { email: 'example@prefab.cloud' })).unwrapped_value
    assert_equal DESIRED_VALUE, evaluator.evaluate(context(user: { email: 'example@hotmail.com' })).unwrapped_value
  end

  def test_not_in_seg
    segment_key = 'segment_key'

    segment_config = PrefabProto::Config.new(
      config_type: PrefabProto::ConfigType::SEGMENT,
      key: segment_key,
      rows: [
        PrefabProto::ConfigRow.new(
          values: [
            PrefabProto::ConditionalValue.new(
              value: TRUE_CONFIG,
              criteria: [
                PrefabProto::Criterion.new(
                  operator: PrefabProto::Criterion::CriterionOperator::PROP_ENDS_WITH_ONE_OF,
                  value_to_match: string_list(['hotmail.com', 'gmail.com']),
                  property_name: 'user.email'
                )
              ]
            ),
            PrefabProto::ConditionalValue.new(value: FALSE_CONFIG)
          ]
        )
      ]
    )

    config = PrefabProto::Config.new(
      key: KEY,
      rows: [
        DEFAULT_ROW,
        PrefabProto::ConfigRow.new(
          project_env_id: PROJECT_ENV_ID,
          values: [
            PrefabProto::ConditionalValue.new(
              criteria: [
                PrefabProto::Criterion.new(
                  operator: PrefabProto::Criterion::CriterionOperator::NOT_IN_SEG,
                  value_to_match: PrefabProto::ConfigValue.new(string: segment_key)
                )
              ],
              value: DESIRED_VALUE_CONFIG
            )
          ]
        )
      ]
    )

    evaluator = Quonfig::CriteriaEvaluator.new(config, project_env_id: PROJECT_ENV_ID,
                                                      base_client: @base_client, namespace: nil,
                                                      resolver: resolver_fake({ segment_key => segment_config }))

    assert_equal DESIRED_VALUE, evaluator.evaluate(context({})).unwrapped_value
    assert_equal DESIRED_VALUE, evaluator.evaluate(context(user: { email: 'example@prefab.cloud' })).unwrapped_value
    assert_equal DEFAULT_VALUE, evaluator.evaluate(context(user: { email: 'example@hotmail.com' })).unwrapped_value
  end

  def test_multiple_conditions_in_one_value
    segment_key = 'segment_key'

    segment_config = PrefabProto::Config.new(
      config_type: PrefabProto::ConfigType::SEGMENT,
      key: segment_key,
      rows: [
        PrefabProto::ConfigRow.new(
          values: [
            PrefabProto::ConditionalValue.new(
              value: TRUE_CONFIG,
              criteria: [
                PrefabProto::Criterion.new(
                  operator: PrefabProto::Criterion::CriterionOperator::PROP_ENDS_WITH_ONE_OF,
                  value_to_match: string_list(['prefab.cloud', 'gmail.com']),
                  property_name: 'user.email'
                ),

                PrefabProto::Criterion.new(
                  operator: PrefabProto::Criterion::CriterionOperator::PROP_IS_ONE_OF,
                  value_to_match: TRUE_CONFIG,
                  property_name: 'user.admin'
                )
              ]
            ),
            PrefabProto::ConditionalValue.new(value: FALSE_CONFIG)
          ]
        )
      ]
    )

    config = PrefabProto::Config.new(
      key: KEY,
      rows: [
        DEFAULT_ROW,
        PrefabProto::ConfigRow.new(
          project_env_id: PROJECT_ENV_ID,
          values: [
            PrefabProto::ConditionalValue.new(
              criteria: [
                PrefabProto::Criterion.new(
                  operator: PrefabProto::Criterion::CriterionOperator::IN_SEG,
                  value_to_match: PrefabProto::ConfigValue.new(string: segment_key)
                ),

                PrefabProto::Criterion.new(
                  operator: PrefabProto::Criterion::CriterionOperator::PROP_IS_NOT_ONE_OF,
                  value_to_match: TRUE_CONFIG,
                  property_name: 'user.deleted'
                )
              ],
              value: DESIRED_VALUE_CONFIG
            )
          ]
        )
      ]
    )

    evaluator = Quonfig::CriteriaEvaluator.new(config, project_env_id: PROJECT_ENV_ID,
                                                      base_client: @base_client, namespace: nil,
                                                      resolver: resolver_fake({ segment_key => segment_config }))

    assert_equal DEFAULT_VALUE, evaluator.evaluate(context({})).unwrapped_value
    assert_equal DEFAULT_VALUE, evaluator.evaluate(context(user: { email: 'example@prefab.cloud' })).unwrapped_value
    assert_equal DESIRED_VALUE, evaluator.evaluate(context(user: { email: 'example@prefab.cloud', admin: true })).unwrapped_value
    assert_equal DEFAULT_VALUE,
                 evaluator.evaluate(context(user: { email: 'example@prefab.cloud', admin: true, deleted: true })).unwrapped_value
    assert_equal DEFAULT_VALUE, evaluator.evaluate(context(user: { email: 'example@gmail.com' })).unwrapped_value
    assert_equal DESIRED_VALUE, evaluator.evaluate(context(user: { email: 'example@gmail.com', admin: true })).unwrapped_value
    assert_equal DEFAULT_VALUE,
                 evaluator.evaluate(context(user: { email: 'example@gmail.com', admin: true, deleted: true })).unwrapped_value
  end

  def test_multiple_conditions_in_multiple_values
    segment_key = 'segment_key'

    segment_config = PrefabProto::Config.new(
      config_type: PrefabProto::ConfigType::SEGMENT,
      key: segment_key,
      rows: [
        PrefabProto::ConfigRow.new(
          values: [
            PrefabProto::ConditionalValue.new(
              value: TRUE_CONFIG,
              criteria: [
                PrefabProto::Criterion.new(
                  operator: PrefabProto::Criterion::CriterionOperator::PROP_ENDS_WITH_ONE_OF,
                  value_to_match: string_list(['prefab.cloud', 'gmail.com']),
                  property_name: 'user.email'
                )
              ]
            ),
            PrefabProto::ConditionalValue.new(
              value: TRUE_CONFIG,
              criteria: [
                PrefabProto::Criterion.new(
                  operator: PrefabProto::Criterion::CriterionOperator::PROP_IS_ONE_OF,
                  value_to_match: TRUE_CONFIG,
                  property_name: 'user.admin'
                )
              ]
            ),
            PrefabProto::ConditionalValue.new(value: FALSE_CONFIG)
          ]
        )
      ]
    )

    config = PrefabProto::Config.new(
      key: KEY,
      rows: [
        DEFAULT_ROW,
        PrefabProto::ConfigRow.new(
          project_env_id: PROJECT_ENV_ID,
          values: [
            PrefabProto::ConditionalValue.new(
              criteria: [
                PrefabProto::Criterion.new(
                  operator: PrefabProto::Criterion::CriterionOperator::IN_SEG,
                  value_to_match: PrefabProto::ConfigValue.new(string: segment_key)
                ),

                PrefabProto::Criterion.new(
                  operator: PrefabProto::Criterion::CriterionOperator::PROP_IS_NOT_ONE_OF,
                  value_to_match: TRUE_CONFIG,
                  property_name: 'user.deleted'
                )
              ],
              value: DESIRED_VALUE_CONFIG
            )
          ]
        )
      ]
    )

    evaluator = Quonfig::CriteriaEvaluator.new(config, project_env_id: PROJECT_ENV_ID,
                                                      base_client: @base_client, namespace: nil,
                                                      resolver: resolver_fake({ segment_key => segment_config }))

    assert_equal DEFAULT_VALUE, evaluator.evaluate(context({})).unwrapped_value
    assert_equal DESIRED_VALUE, evaluator.evaluate(context(user: { email: 'example@prefab.cloud' })).unwrapped_value
    assert_equal DESIRED_VALUE, evaluator.evaluate(context(user: { admin: true })).unwrapped_value
    assert_equal DESIRED_VALUE, evaluator.evaluate(context(user: { email: 'example@prefab.cloud', admin: true })).unwrapped_value
    assert_equal DEFAULT_VALUE,
                 evaluator.evaluate(context(user: { email: 'example@prefab.cloud', admin: true, deleted: true })).unwrapped_value
    assert_equal DESIRED_VALUE, evaluator.evaluate(context(user: { email: 'example@gmail.com' })).unwrapped_value
    assert_equal DESIRED_VALUE, evaluator.evaluate(context(user: { email: 'example@gmail.com', admin: true })).unwrapped_value
    assert_equal DEFAULT_VALUE,
                 evaluator.evaluate(context(user: { email: 'example@gmail.com', admin: true, deleted: true })).unwrapped_value
  end

  def test_stringifying_property_values_and_names
    config = PrefabProto::Config.new(
      key: KEY,
      rows: [
        DEFAULT_ROW,
        PrefabProto::ConfigRow.new(
          project_env_id: PROJECT_ENV_ID,
          values: [
            PrefabProto::ConditionalValue.new(
              criteria: [
                PrefabProto::Criterion.new(
                  operator: PrefabProto::Criterion::CriterionOperator::PROP_IS_ONE_OF,
                  value_to_match: string_list(%w[1 true hello]),
                  property_name: 'team.name'
                )
              ],
              value: DESIRED_VALUE_CONFIG
            )
          ]
        )
      ]
    )

    evaluator = Quonfig::CriteriaEvaluator.new(config, project_env_id: PROJECT_ENV_ID, resolver: nil,
                                                      namespace: nil, base_client: @base_client)

    assert_equal DEFAULT_VALUE, evaluator.evaluate(context({})).unwrapped_value
    assert_equal DEFAULT_VALUE, evaluator.evaluate(context(team: { name: 'prefab.cloud' })).unwrapped_value

    [1, true, :hello].each do |value|
      [:name, 'name'].each do |property_name|
        assert_equal DESIRED_VALUE, evaluator.evaluate(context(team: { property_name => value })).unwrapped_value
        assert_equal DESIRED_VALUE, evaluator.evaluate(context(team: { property_name => value.to_s })).unwrapped_value
      end
    end
  end

  def test_in_int_range
    config = PrefabProto::Config.new(
      key: KEY,
      rows: [
        PrefabProto::ConfigRow.new(
          project_env_id: PROJECT_ENV_ID,
          values: [
            PrefabProto::ConditionalValue.new(
              criteria: [
                PrefabProto::Criterion.new(operator: PrefabProto::Criterion::CriterionOperator::IN_INT_RANGE,
                                           value_to_match: PrefabProto::ConfigValue.new(int_range: PrefabProto::IntRange.new(start: 30, end: 40)), property_name: 'user.age')
              ],
              value: DESIRED_VALUE_CONFIG
            ),

            PrefabProto::ConditionalValue.new(
              criteria: [
                PrefabProto::Criterion.new(operator: PrefabProto::Criterion::CriterionOperator::ALWAYS_TRUE)
              ],
              value: PrefabProto::ConfigValue.new(string: DEFAULT_VALUE)
            )
          ]
        )
      ]
    )

    evaluator = Quonfig::CriteriaEvaluator.new(config, project_env_id: PROJECT_ENV_ID, resolver: nil,
                                                      namespace: nil, base_client: @base_client)

    assert_equal DEFAULT_VALUE, evaluator.evaluate(context({})).unwrapped_value
    assert_equal DESIRED_VALUE, evaluator.evaluate(context({ 'user' => { 'age' => 32 } })).unwrapped_value
    assert_equal DEFAULT_VALUE, evaluator.evaluate(context({ 'user' => { 'age' => 29 } })).unwrapped_value
    assert_equal DEFAULT_VALUE, evaluator.evaluate(context({ 'user' => { 'age' => 41 } })).unwrapped_value
  end

  def test_in_int_range_for_time
    now = Time.now

    config = PrefabProto::Config.new(
      key: KEY,
      rows: [
        PrefabProto::ConfigRow.new(
          project_env_id: PROJECT_ENV_ID,
          values: [
            PrefabProto::ConditionalValue.new(
              criteria: [
                PrefabProto::Criterion.new(operator: PrefabProto::Criterion::CriterionOperator::IN_INT_RANGE,
                                           value_to_match: PrefabProto::ConfigValue.new(
                                             int_range: PrefabProto::IntRange.new(
                                               start: (now.to_i - 60) * 1000, end: (now.to_i + 60) * 1000
                                             )
                                           ), property_name: 'prefab.current-time')
              ],
              value: DESIRED_VALUE_CONFIG
            ),

            PrefabProto::ConditionalValue.new(
              criteria: [
                PrefabProto::Criterion.new(operator: PrefabProto::Criterion::CriterionOperator::ALWAYS_TRUE)
              ],
              value: PrefabProto::ConfigValue.new(string: DEFAULT_VALUE)
            )
          ]
        )
      ]
    )

    evaluator = Quonfig::CriteriaEvaluator.new(config, project_env_id: PROJECT_ENV_ID, resolver: nil,
                                                      namespace: nil, base_client: @base_client)

    Timecop.freeze(now) do
      assert_equal DESIRED_VALUE, evaluator.evaluate(context({})).unwrapped_value
    end

    Timecop.freeze(now - 60) do
      assert_equal DESIRED_VALUE, evaluator.evaluate(context({})).unwrapped_value
    end

    Timecop.freeze(now - 61) do
      assert_equal DEFAULT_VALUE, evaluator.evaluate(context({})).unwrapped_value
    end

    Timecop.freeze(now + 59) do
      assert_equal DESIRED_VALUE, evaluator.evaluate(context({})).unwrapped_value
    end

    Timecop.freeze(now + 60) do
      assert_equal DEFAULT_VALUE, evaluator.evaluate(context({})).unwrapped_value
    end
  end

  def test_evaluating_a_log_level
    config = PrefabProto::Config.new(
      id: 999,
      key: 'log-level',
      config_type: PrefabProto::ConfigType::LOG_LEVEL,
      rows: [
        PrefabProto::ConfigRow.new(
          values: [
            PrefabProto::ConditionalValue.new(
              criteria: [PrefabProto::Criterion.new(operator: PrefabProto::Criterion::CriterionOperator::ALWAYS_TRUE)],
              value: PrefabProto::ConfigValue.new(log_level: PrefabProto::LogLevel::DEBUG)
            )
          ]
        )
      ]
    )

    evaluator = Quonfig::CriteriaEvaluator.new(config, project_env_id: PROJECT_ENV_ID, resolver: nil, base_client: @base_client, namespace: nil)

    assert_equal :DEBUG, evaluator.evaluate(context({})).unwrapped_value
  end

  def test_evaluating_a_weighted_value
    config = PrefabProto::Config.new(
      id: 123,
      key: KEY,
      config_type: PrefabProto::ConfigType::CONFIG,
      rows: [
        PrefabProto::ConfigRow.new(
          project_env_id: PROJECT_ENV_ID,
          values: [
            PrefabProto::ConditionalValue.new(
              criteria: [PrefabProto::Criterion.new(operator: PrefabProto::Criterion::CriterionOperator::ALWAYS_TRUE)],
              value: PrefabProto::ConfigValue.new(weighted_values: weighted_values([['abc', 98], ['def', 1], ['ghi', 1]]))
            )
          ]
        )
      ]
    )

    evaluator = Quonfig::CriteriaEvaluator.new(config, project_env_id: PROJECT_ENV_ID, resolver: nil, base_client: @base_client, namespace: nil)

    2.times do
      assert_equal 'abc', evaluator.evaluate(context('user' => { 'key' => '1' })).unwrapped_value
    end

    3.times do
      context = context({ 'user' => { 'key' => '12' } })
      assert_equal 'def', evaluator.evaluate(context).unwrapped_value
    end

    context = context({ 'user' => { 'key' => '4' } })
    assert_equal 'ghi', evaluator.evaluate(context).unwrapped_value
  end

  def test_prop_regex_matches
    config = PrefabProto::Config.new(
      key: KEY,
      rows: [
        DEFAULT_ROW,
        PrefabProto::ConfigRow.new(
          project_env_id: PROJECT_ENV_ID,
          values: [
            PrefabProto::ConditionalValue.new(
              criteria: [
                PrefabProto::Criterion.new(
                  operator: PrefabProto::Criterion::CriterionOperator::PROP_MATCHES,
                  value_to_match: PrefabProto::ConfigValue.new(string: "a+b+"),
                  property_name: 'user.testProperty'
                )
              ],
              value: DESIRED_VALUE_CONFIG
            )
          ]
        )
      ]
    )

    evaluator = Quonfig::CriteriaEvaluator.new(config, project_env_id: PROJECT_ENV_ID, resolver: nil, base_client: @base_client,
                                              namespace: nil)

    assert_equal DEFAULT_VALUE, evaluator.evaluate(context({})).unwrapped_value
    assert_equal DEFAULT_VALUE, evaluator.evaluate(context(user: { testProperty: 'abc' })).unwrapped_value
    assert_equal DESIRED_VALUE, evaluator.evaluate(context(user: { testProperty: 'aabb' })).unwrapped_value
  end

  def test_prop_regex_does_not_match
    config = PrefabProto::Config.new(
      key: KEY,
      rows: [
        DEFAULT_ROW,
        PrefabProto::ConfigRow.new(
          project_env_id: PROJECT_ENV_ID,
          values: [
            PrefabProto::ConditionalValue.new(
              criteria: [
                PrefabProto::Criterion.new(
                  operator: PrefabProto::Criterion::CriterionOperator::PROP_DOES_NOT_MATCH,
                  value_to_match: PrefabProto::ConfigValue.new(string: "a+b+"),
                  property_name: 'user.testProperty'
                )
              ],
              value: DESIRED_VALUE_CONFIG
            )
          ]
        )
      ]
    )

    evaluator = Quonfig::CriteriaEvaluator.new(config, project_env_id: PROJECT_ENV_ID, resolver: nil, base_client: @base_client,
                                              namespace: nil)

    assert_equal DESIRED_VALUE, evaluator.evaluate(context({})).unwrapped_value
    assert_equal DESIRED_VALUE, evaluator.evaluate(context(user: { testProperty: 'abc' })).unwrapped_value
    assert_equal DEFAULT_VALUE, evaluator.evaluate(context(user: { testProperty: 'aabb' })).unwrapped_value
  end

  def test_prop_regex_does_not_match_returns_false_bad_regex
    config = PrefabProto::Config.new(
      key: KEY,
      rows: [
        DEFAULT_ROW,
        PrefabProto::ConfigRow.new(
          project_env_id: PROJECT_ENV_ID,
          values: [
            PrefabProto::ConditionalValue.new(
              criteria: [
                PrefabProto::Criterion.new(
                  operator: PrefabProto::Criterion::CriterionOperator::PROP_DOES_NOT_MATCH,
                  value_to_match: PrefabProto::ConfigValue.new(string: "[a+b+"),
                  property_name: 'user.testProperty'
                )
              ],
              value: DESIRED_VALUE_CONFIG
            )
          ]
        )
      ]
    )

    evaluator = Quonfig::CriteriaEvaluator.new(config, project_env_id: PROJECT_ENV_ID, resolver: nil, base_client: @base_client,
                                              namespace: nil)
    assert_equal DEFAULT_VALUE, evaluator.evaluate(context({})).unwrapped_value
    assert_equal DEFAULT_VALUE, evaluator.evaluate(context(user: { testProperty: 'abc' })).unwrapped_value

    assert_stderr [ "warning: character class has duplicated range: /^[a+b+$/" ]
  end


  def test_prop_regex_match_returns_false_bad_regex
    config = PrefabProto::Config.new(
      key: KEY,
      rows: [
        DEFAULT_ROW,
        PrefabProto::ConfigRow.new(
          project_env_id: PROJECT_ENV_ID,
          values: [
            PrefabProto::ConditionalValue.new(
              criteria: [
                PrefabProto::Criterion.new(
                  operator: PrefabProto::Criterion::CriterionOperator::PROP_MATCHES,
                  value_to_match: PrefabProto::ConfigValue.new(string: "[a+b+"),
                  property_name: 'user.testProperty'
                )
              ],
              value: DESIRED_VALUE_CONFIG
            )
          ]
        )
      ]
    )

    evaluator = Quonfig::CriteriaEvaluator.new(config, project_env_id: PROJECT_ENV_ID, resolver: nil, base_client: @base_client,
                                              namespace: nil)

    assert_equal DEFAULT_VALUE, evaluator.evaluate(context({})).unwrapped_value
    assert_equal DEFAULT_VALUE, evaluator.evaluate(context(user: { testProperty: 'abc' })).unwrapped_value

    assert_stderr [ "warning: character class has duplicated range: /^[a+b+$/" ]
  end

  def test_less_than_works
    config = create_prefab_config(operator: PrefabProto::Criterion::CriterionOperator::PROP_LESS_THAN, property_name: 'user.age', value_to_match: 10)
    evaluator = Quonfig::CriteriaEvaluator.new(config, project_env_id: PROJECT_ENV_ID, resolver: nil, base_client: @base_client,
                                              namespace: nil)
    assert_equal DEFAULT_VALUE, evaluator.evaluate(context({})).unwrapped_value
    assert_equal DEFAULT_VALUE, evaluator.evaluate(context(user: {age: 10})).unwrapped_value
    assert_equal DESIRED_VALUE, evaluator.evaluate(context(user: {age: 9})).unwrapped_value
    assert_equal DESIRED_VALUE, evaluator.evaluate(context(user: {age: 9.5})).unwrapped_value
    assert_equal DEFAULT_VALUE, evaluator.evaluate(context(user: {age: 10.1})).unwrapped_value
    assert_equal DEFAULT_VALUE, evaluator.evaluate(context(user: {age: "9"})).unwrapped_value
    assert_equal DEFAULT_VALUE, evaluator.evaluate(context(user: {age: "9.2"})).unwrapped_value
    assert_equal DEFAULT_VALUE, evaluator.evaluate(context(user: {age: "not a number"})).unwrapped_value
  end

  def test_less_or_equal_to_works
    config = create_prefab_config(operator: PrefabProto::Criterion::CriterionOperator::PROP_LESS_THAN_OR_EQUAL, property_name: 'user.age', value_to_match: 10)
    evaluator = Quonfig::CriteriaEvaluator.new(config, project_env_id: PROJECT_ENV_ID, resolver: nil, base_client: @base_client,
                                              namespace: nil)
    assert_equal DEFAULT_VALUE, evaluator.evaluate(context({})).unwrapped_value
    assert_equal DESIRED_VALUE, evaluator.evaluate(context(user: {age: 10})).unwrapped_value
    assert_equal DESIRED_VALUE, evaluator.evaluate(context(user: {age: 9})).unwrapped_value
    assert_equal DESIRED_VALUE, evaluator.evaluate(context(user: {age: 9.5})).unwrapped_value
    assert_equal DEFAULT_VALUE, evaluator.evaluate(context(user: {age: 10.1})).unwrapped_value
    assert_equal DEFAULT_VALUE, evaluator.evaluate(context(user: {age: "9"})).unwrapped_value
    assert_equal DEFAULT_VALUE, evaluator.evaluate(context(user: {age: "not a number"})).unwrapped_value
  end


  def test_greater_than_works
    config = create_prefab_config(operator: PrefabProto::Criterion::CriterionOperator::PROP_GREATER_THAN, property_name: 'user.age', value_to_match: 10)
    evaluator = Quonfig::CriteriaEvaluator.new(config, project_env_id: PROJECT_ENV_ID, resolver: nil, base_client: @base_client,
                                              namespace: nil)
    assert_equal DEFAULT_VALUE, evaluator.evaluate(context({})).unwrapped_value
    assert_equal DEFAULT_VALUE, evaluator.evaluate(context(user: {age: 10})).unwrapped_value
    assert_equal DEFAULT_VALUE, evaluator.evaluate(context(user: {age: 9})).unwrapped_value
    assert_equal DEFAULT_VALUE, evaluator.evaluate(context(user: {age: 9.5})).unwrapped_value
    assert_equal DESIRED_VALUE, evaluator.evaluate(context(user: {age: 10.1})).unwrapped_value
    assert_equal DESIRED_VALUE, evaluator.evaluate(context(user: {age: 12})).unwrapped_value
    assert_equal DEFAULT_VALUE, evaluator.evaluate(context(user: {age: "19"})).unwrapped_value
    assert_equal DEFAULT_VALUE, evaluator.evaluate(context(user: {age: "not a number"})).unwrapped_value
  end

  def test_greater_than_or_equal_to_works
    config = create_prefab_config(operator: PrefabProto::Criterion::CriterionOperator::PROP_GREATER_THAN_OR_EQUAL, property_name: 'user.age', value_to_match: 10)
    evaluator = Quonfig::CriteriaEvaluator.new(config, project_env_id: PROJECT_ENV_ID, resolver: nil, base_client: @base_client,
                                              namespace: nil)
    assert_equal DEFAULT_VALUE, evaluator.evaluate(context({})).unwrapped_value
    assert_equal DESIRED_VALUE, evaluator.evaluate(context(user: {age: 10})).unwrapped_value
    assert_equal DEFAULT_VALUE, evaluator.evaluate(context(user: {age: 9})).unwrapped_value
    assert_equal DEFAULT_VALUE, evaluator.evaluate(context(user: {age: 9.5})).unwrapped_value
    assert_equal DESIRED_VALUE, evaluator.evaluate(context(user: {age: 10.1})).unwrapped_value
    assert_equal DESIRED_VALUE, evaluator.evaluate(context(user: {age: 12})).unwrapped_value

    assert_equal DEFAULT_VALUE, evaluator.evaluate(context(user: {age: "19"})).unwrapped_value
    assert_equal DEFAULT_VALUE, evaluator.evaluate(context(user: {age: "not a number"})).unwrapped_value
  end

  def test_date_before_works
    date = "2024-12-01T00:00:00Z"
    millis = Time.iso8601(date).utc.to_i * 1000
    config_with_string = create_prefab_config(operator: PrefabProto::Criterion::CriterionOperator::PROP_BEFORE, property_name: 'user.joinDate', value_to_match: date)
    evaluator_with_string_config = Quonfig::CriteriaEvaluator.new(config_with_string, project_env_id: PROJECT_ENV_ID, resolver: nil, base_client: @base_client,
                                              namespace: nil)
    config_with_millis = create_prefab_config(operator: PrefabProto::Criterion::CriterionOperator::PROP_BEFORE, property_name: 'user.joinDate', value_to_match: millis)
    evaluator_with_millis_config = Quonfig::CriteriaEvaluator.new(config_with_millis, project_env_id: PROJECT_ENV_ID, resolver: nil, base_client: @base_client,
                                                                 namespace: nil)
    assert_equal DEFAULT_VALUE, evaluator_with_millis_config.evaluate(context({})).unwrapped_value
    assert_equal DESIRED_VALUE, evaluator_with_millis_config.evaluate(context(user: {joinDate: millis-10000})).unwrapped_value
    assert_equal DESIRED_VALUE, evaluator_with_millis_config.evaluate(context(user: {joinDate: "2024-11-01T00:00:00Z"})).unwrapped_value
    assert_equal DEFAULT_VALUE, evaluator_with_millis_config.evaluate(context(user: {joinDate: millis+10000})).unwrapped_value
    assert_equal DEFAULT_VALUE, evaluator_with_millis_config.evaluate(context(user: {joinDate: "2024-12-02T00:00:00Z"})).unwrapped_value

    assert_equal DEFAULT_VALUE, evaluator_with_string_config.evaluate(context({})).unwrapped_value
    assert_equal DESIRED_VALUE, evaluator_with_string_config.evaluate(context(user: {joinDate: millis-10000})).unwrapped_value
    assert_equal DESIRED_VALUE, evaluator_with_string_config.evaluate(context(user: {joinDate: "2024-11-01T00:00:00Z"})).unwrapped_value
    assert_equal DEFAULT_VALUE, evaluator_with_string_config.evaluate(context(user: {joinDate: millis+10000})).unwrapped_value
    assert_equal DEFAULT_VALUE, evaluator_with_string_config.evaluate(context(user: {joinDate: "2024-12-02T00:00:00Z"})).unwrapped_value
  end

  def test_date_after_works
    date = "2024-12-01T00:00:00Z"
    millis = Time.iso8601(date).utc.to_i * 1000
    config_with_string = create_prefab_config(operator: PrefabProto::Criterion::CriterionOperator::PROP_AFTER, property_name: 'user.joinDate', value_to_match: date)
    evaluator_with_string_config = Quonfig::CriteriaEvaluator.new(config_with_string, project_env_id: PROJECT_ENV_ID, resolver: nil, base_client: @base_client,
                                                                 namespace: nil)
    config_with_millis = create_prefab_config(operator: PrefabProto::Criterion::CriterionOperator::PROP_AFTER, property_name: 'user.joinDate', value_to_match: millis)
    evaluator_with_millis_config = Quonfig::CriteriaEvaluator.new(config_with_millis, project_env_id: PROJECT_ENV_ID, resolver: nil, base_client: @base_client,
                                                                 namespace: nil)
    assert_equal DEFAULT_VALUE, evaluator_with_millis_config.evaluate(context({})).unwrapped_value
    assert_equal DEFAULT_VALUE, evaluator_with_millis_config.evaluate(context(user: {joinDate: millis-10000})).unwrapped_value
    assert_equal DEFAULT_VALUE, evaluator_with_millis_config.evaluate(context(user: {joinDate: "2024-11-01T00:00:00Z"})).unwrapped_value
    assert_equal DESIRED_VALUE, evaluator_with_millis_config.evaluate(context(user: {joinDate: millis+10000})).unwrapped_value
    assert_equal DESIRED_VALUE, evaluator_with_millis_config.evaluate(context(user: {joinDate: "2024-12-02T00:00:00Z"})).unwrapped_value

    assert_equal DEFAULT_VALUE, evaluator_with_string_config.evaluate(context({})).unwrapped_value
    assert_equal DEFAULT_VALUE, evaluator_with_string_config.evaluate(context(user: {joinDate: millis-10000})).unwrapped_value
    assert_equal DEFAULT_VALUE, evaluator_with_string_config.evaluate(context(user: {joinDate: "2024-11-01T00:00:00Z"})).unwrapped_value
    assert_equal DESIRED_VALUE, evaluator_with_string_config.evaluate(context(user: {joinDate: millis+10000})).unwrapped_value
    assert_equal DESIRED_VALUE, evaluator_with_string_config.evaluate(context(user: {joinDate: "2024-12-02T00:00:00Z"})).unwrapped_value
  end

  def test_semver_less_than
    config = create_prefab_config(operator: PrefabProto::Criterion::CriterionOperator::PROP_SEMVER_LESS_THAN, property_name: 'user.version', value_to_match: "2.0.0")
    evaluator = Quonfig::CriteriaEvaluator.new(config, project_env_id: PROJECT_ENV_ID, resolver: nil, base_client: @base_client, namespace: nil)
    assert_equal DEFAULT_VALUE, evaluator.evaluate(context({})).unwrapped_value
    assert_equal DEFAULT_VALUE, evaluator.evaluate(context(user:{version: "nonsense"})).unwrapped_value

    assert_equal DESIRED_VALUE, evaluator.evaluate(context(user:{version: "1.0.0"})).unwrapped_value
    assert_equal DEFAULT_VALUE, evaluator.evaluate(context(user:{version: "2.0.0"})).unwrapped_value
    assert_equal DEFAULT_VALUE, evaluator.evaluate(context(user:{version: "3.0.0"})).unwrapped_value
  end

  def test_semver_equal_to
    config = create_prefab_config(operator: PrefabProto::Criterion::CriterionOperator::PROP_SEMVER_EQUAL, property_name: 'user.version', value_to_match: "2.0.0")
    evaluator = Quonfig::CriteriaEvaluator.new(config, project_env_id: PROJECT_ENV_ID, resolver: nil, base_client: @base_client, namespace: nil)
    assert_equal DEFAULT_VALUE, evaluator.evaluate(context({})).unwrapped_value
    assert_equal DEFAULT_VALUE, evaluator.evaluate(context(user:{version: "nonsense"})).unwrapped_value

    assert_equal DEFAULT_VALUE, evaluator.evaluate(context(user:{version: "1.0.0"})).unwrapped_value
    assert_equal DESIRED_VALUE, evaluator.evaluate(context(user:{version: "2.0.0"})).unwrapped_value
    assert_equal DEFAULT_VALUE, evaluator.evaluate(context(user:{version: "3.0.0"})).unwrapped_value
  end

  def test_semver_greater_than
    config = create_prefab_config(operator: PrefabProto::Criterion::CriterionOperator::PROP_SEMVER_GREATER_THAN, property_name: 'user.version', value_to_match: "2.0.0")
    evaluator = Quonfig::CriteriaEvaluator.new(config, project_env_id: PROJECT_ENV_ID, resolver: nil, base_client: @base_client, namespace: nil)
    assert_equal DEFAULT_VALUE, evaluator.evaluate(context({})).unwrapped_value
    assert_equal DEFAULT_VALUE, evaluator.evaluate(context(user:{version: "nonsense"})).unwrapped_value

    assert_equal DEFAULT_VALUE, evaluator.evaluate(context(user:{version: "1.0.0"})).unwrapped_value
    assert_equal DEFAULT_VALUE, evaluator.evaluate(context(user:{version: "2.0.0"})).unwrapped_value
    assert_equal DESIRED_VALUE, evaluator.evaluate(context(user:{version: "3.0.0"})).unwrapped_value
  end

  def test_date_before_with_current_time
    future_time = Time.now.utc + 3600 # 1 hour in the future
    config = create_prefab_config(
      operator: PrefabProto::Criterion::CriterionOperator::PROP_BEFORE,
      property_name: 'prefab.current-time',
      value_to_match: future_time.iso8601
    )
    evaluator = Quonfig::CriteriaEvaluator.new(config, project_env_id: PROJECT_ENV_ID, resolver: nil, base_client: @base_client, namespace: nil)
    assert_equal DESIRED_VALUE, evaluator.evaluate(context({})).unwrapped_value
  end

  def test_date_after_with_current_time
    past_time = Time.now.utc - 3600 # 1 hour in the past
    config = create_prefab_config(
      operator: PrefabProto::Criterion::CriterionOperator::PROP_AFTER,
      property_name: 'prefab.current-time',
      value_to_match: past_time.iso8601
    )
    evaluator = Quonfig::CriteriaEvaluator.new(config, project_env_id: PROJECT_ENV_ID, resolver: nil, base_client: @base_client, namespace: nil)
    assert_equal DESIRED_VALUE, evaluator.evaluate(context({})).unwrapped_value
  end

  private

  def string_list(values)
    PrefabProto::ConfigValue.new(string_list: PrefabProto::StringList.new(values: values))
  end

  class FakeResolver
    def initialize(config, base_client)
      @config = config
      @base_client = base_client
    end

    def raw(key)
      @config[key]
    end

    def get(key, properties = {})
      # This only gets called for segments, so we don't need to pass in a resolver
      Quonfig::CriteriaEvaluator.new(@config[key], project_env_id: nil, resolver: nil,
                                                  namespace: nil, base_client: @base_client).evaluate(properties)
    end
  end

  def resolver_fake(config)
    FakeResolver.new(config, @base_client)
  end

  class FakeBaseClient
    def evaluation_summary_aggregator
      @evaluation_summary_aggregator ||= Quonfig::EvaluationSummaryAggregator.new(client: self, max_keys: 9999, sync_interval: 9999)
    end

    def instance_hash
      'fake-base-client-instance_hash'
    end
  end


  def create_prefab_config(
    key: KEY,
    project_env_id: PROJECT_ENV_ID,
    operator:,
    value_to_match:,
    property_name:,
    desired_value_config: DESIRED_VALUE_CONFIG
  )
    PrefabProto::Config.new(
      key: key,
      rows: [
        DEFAULT_ROW,
        PrefabProto::ConfigRow.new(
          project_env_id: project_env_id,
          values: [
            PrefabProto::ConditionalValue.new(
              criteria: [
                PrefabProto::Criterion.new(
                  operator: operator,
                  value_to_match: build_config_value(value_to_match),
                  property_name: property_name
                )
              ],
              value: desired_value_config
            )
          ]
        )
      ]
    )
  end

  def build_config_value(value)
    case value
    when Integer
      PrefabProto::ConfigValue.new(int: value)
    when Float
      PrefabProto::ConfigValue.new(double: value)
    when String
      PrefabProto::ConfigValue.new(string: value)
    when Array
      if value.all? { |v| v.is_a?(String) }
        PrefabProto::ConfigValue.new(string_list: PrefabProto::StringList.new(values: value))
      else
        raise ArgumentError, "Unsupported array type: Only arrays of strings are supported."
      end
    else
      raise ArgumentError, "Unsupported value type: #{value.class}"
    end
  end
end
