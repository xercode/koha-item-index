#!/usr/bin/perl
#
# This file is part of Koha.
#
# Koha is free software; you can redistribute it and/or modify it
# under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 3 of the License, or
# (at your option) any later version.
#
# Koha is distributed in the hope that it will be useful, but
# WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with Koha; if not, see <https://www.gnu.org/licenses>.

use Modern::Perl;

use Test::NoWarnings;
use Test::More tests => 14;
use Test::Warn;
use t::lib::Mocks;
use JSON;

use_ok('Koha::SearchEngine::Elasticsearch::QueryBuilder');

subtest 'query_regex_escape_options' => sub {
    plan tests => 12;

    t::lib::Mocks::mock_preference( 'QueryRegexEscapeOptions', 'dont_escape' );

    my $query_with_regexp = "query /with regexp/";

    my $processed_query =
        Koha::SearchEngine::Elasticsearch::QueryBuilder->_query_regex_escape_process($query_with_regexp);
    is(
        $processed_query,
        $query_with_regexp,
        "Unescaped query regexp has not been escaped when escaping is disabled"
    );

    t::lib::Mocks::mock_preference( 'QueryRegexEscapeOptions', 'escape' );

    $processed_query = Koha::SearchEngine::Elasticsearch::QueryBuilder->_query_regex_escape_process($query_with_regexp);
    is(
        $processed_query,
        "query \\/with regexp\\/",
        "Unescaped query regexp has been escaped when escaping is enabled"
    );

    my $query_with_escaped_regex = "query \\/with regexp\\/";
    $processed_query =
        Koha::SearchEngine::Elasticsearch::QueryBuilder->_query_regex_escape_process($query_with_escaped_regex);
    is(
        $processed_query,
        $query_with_escaped_regex,
        "Escaped query regexp has been left unmodified when escaping is enabled"
    );

    my $query_with_even_preceding_escapes_regex = "query \\\\/with regexp\\\\/";
    $processed_query = Koha::SearchEngine::Elasticsearch::QueryBuilder->_query_regex_escape_process(
        $query_with_even_preceding_escapes_regex);
    is(
        $processed_query,
        "query \\\\\\/with regexp\\\\\\/",
        "Query regexp with even preceding escapes, thus unescaped, has been escaped when escaping is enabled"
    );

    my $query_with_odd_preceding_escapes_regex = 'query \\\\\\/with regexp\\\\\\/';
    $processed_query = Koha::SearchEngine::Elasticsearch::QueryBuilder->_query_regex_escape_process(
        $query_with_odd_preceding_escapes_regex);
    is(
        $processed_query,
        $query_with_odd_preceding_escapes_regex,
        "Query regexp with odd preceding escapes, thus escaped, has been left unmodified when escaping is enabled"
    );

    my $query_with_quoted_slash = "query with / and \"/ within quotes\"";
    $processed_query =
        Koha::SearchEngine::Elasticsearch::QueryBuilder->_query_regex_escape_process($query_with_quoted_slash);
    is(
        $processed_query,
        "query with \\/ and \"/ within quotes\"",
        "Unescaped slash outside of quotes has been escaped while unescaped slash within quotes is left as is when escaping is enabled."
    );

    t::lib::Mocks::mock_preference( 'QueryRegexEscapeOptions', 'unescape_escaped' );

    $processed_query = Koha::SearchEngine::Elasticsearch::QueryBuilder->_query_regex_escape_process($query_with_regexp);
    is(
        $processed_query,
        "query \\/with regexp\\/",
        "Unescaped query regexp has been escaped when unescape escaping is enabled"
    );

    $processed_query =
        Koha::SearchEngine::Elasticsearch::QueryBuilder->_query_regex_escape_process($query_with_escaped_regex);
    is(
        $processed_query,
        "query /with regexp/",
        "Escaped query regexp has been unescaped when unescape escaping is enabled"
    );

    $processed_query = Koha::SearchEngine::Elasticsearch::QueryBuilder->_query_regex_escape_process(
        $query_with_even_preceding_escapes_regex);
    is(
        $processed_query,
        "query \\\\\\/with regexp\\\\\\/",
        "Query regexp with even preceding escapes, thus unescaped, has been escaped when unescape escaping is enabled"
    );

    $processed_query = Koha::SearchEngine::Elasticsearch::QueryBuilder->_query_regex_escape_process(
        $query_with_odd_preceding_escapes_regex);
    is(
        $processed_query,
        "query \\\\/with regexp\\\\/",
        "Query regexp with odd preceding escapes, thus escaped, has been unescaped when unescape escaping is enabled"
    );

    my $regexp_at_start_of_string_with_odd_preceding_escapes_regex = '\\\\\\/regexp\\\\\\/';
    $processed_query = Koha::SearchEngine::Elasticsearch::QueryBuilder->_query_regex_escape_process(
        $regexp_at_start_of_string_with_odd_preceding_escapes_regex);
    is(
        $processed_query,
        "\\\\/regexp\\\\/",
        "Regexp at start of string with odd preceding escapes, thus escaped, has been unescaped when unescape escaping is enabled"
    );

    my $query_with_quoted_escaped_slash = "query with \\/ and \"\\/ within quotes\"";
    $processed_query =
        Koha::SearchEngine::Elasticsearch::QueryBuilder->_query_regex_escape_process($query_with_quoted_escaped_slash);
    is(
        $processed_query,
        "query with / and \"\\/ within quotes\"",
        "Escaped slash outside of quotes has been unescaped while escaped slash within quotes is left as is when unescape escaping is enabled."
    );
};

subtest '_truncate_terms() tests' => sub {
    plan tests => 7;

    my $qb;
    ok(
        $qb = Koha::SearchEngine::Elasticsearch::QueryBuilder->new(
            { 'index' => $Koha::SearchEngine::Elasticsearch::BIBLIOS_INDEX }
        ),
        'Creating a new QueryBuilder object'
    );

    my $res = $qb->_truncate_terms('donald');
    is_deeply( $res, 'donald*', 'single search term returned correctly' );

    $res = $qb->_truncate_terms('donald duck');
    is_deeply( $res, 'donald* duck*', 'two search terms returned correctly' );

    $res = $qb->_truncate_terms(' donald   duck ');
    is_deeply( $res, 'donald* duck*', 'two search terms surrounded by spaces returned correctly' );

    $res = $qb->_truncate_terms('"donald duck"');
    is_deeply( $res, '"donald duck"', 'quoted search term returned correctly' );

    $res = $qb->_truncate_terms('"donald, duck"');
    is_deeply( $res, '"donald, duck"', 'quoted search term with comma returned correctly' );

    $res = $qb->_truncate_terms(' "donald   duck" ');
    is_deeply( $res, '"donald   duck"', 'quoted search terms surrounded by spaces correctly' );
};

subtest '_is_safe_to_auto_truncate() tests' => sub {
    plan tests => 7;

    my $qb;
    ok(
        $qb = Koha::SearchEngine::Elasticsearch::QueryBuilder->new(
            { 'index' => $Koha::SearchEngine::Elasticsearch::BIBLIOS_INDEX }
        ),
        'Creating a new QueryBuilder object'
    );

    my $res = $qb->_is_safe_to_auto_truncate( undef, 'local-number:1' );
    is( $res, '0', 'no truncation for biblionumber - OK' );

    $res = $qb->_is_safe_to_auto_truncate( undef, 'koha-auth-number:1' );
    is( $res, '0', 'no truncation for authid - OK' );

    $res = $qb->_is_safe_to_auto_truncate( undef, 'title:some title' );
    is( $res, '1', 'do truncate titles - OK' );

    $res = $qb->_is_safe_to_auto_truncate( 'local-number', undef );
    is( $res, '0', 'no truncation for biblionumber - OK' );

    $res = $qb->_is_safe_to_auto_truncate( 'koha-auth-number', undef );
    is( $res, '0', 'no truncation for authid - OK' );

    $res = $qb->_is_safe_to_auto_truncate( 'title', undef );
    is( $res, '1', 'do truncate titles - OK' );
};

subtest '_split_query() tests' => sub {
    plan tests => 7;

    my $qb;
    ok(
        $qb = Koha::SearchEngine::Elasticsearch::QueryBuilder->new(
            { 'index' => $Koha::SearchEngine::Elasticsearch::BIBLIOS_INDEX }
        ),
        'Creating a new QueryBuilder object'
    );

    my @res = $qb->_split_query('donald');
    my @exp = 'donald';
    is_deeply( \@res, \@exp, 'single search term returned correctly' );

    @res = $qb->_split_query('donald duck');
    @exp = ( 'donald', 'duck' );
    is_deeply( \@res, \@exp, 'two search terms returned correctly' );

    @res = $qb->_split_query(' donald   duck ');
    @exp = ( 'donald', 'duck' );
    is_deeply( \@res, \@exp, 'two search terms surrounded by spaces returned correctly' );

    @res = $qb->_split_query('"donald duck"');
    @exp = ('"donald duck"');
    is_deeply( \@res, \@exp, 'quoted search term returned correctly' );

    @res = $qb->_split_query('"donald, duck"');
    @exp = ('"donald, duck"');
    is_deeply( \@res, \@exp, 'quoted search term with comma returned correctly' );

    @res = $qb->_split_query(' "donald   duck" ');
    @exp = ('"donald   duck"');
    is_deeply( \@res, \@exp, 'quoted search terms surrounded by spaces correctly' );
};

subtest 'clean_search_term() tests' => sub {
    plan tests => 29;

    my $qb;
    ok(
        $qb = Koha::SearchEngine::Elasticsearch::QueryBuilder->new(
            { 'index' => $Koha::SearchEngine::Elasticsearch::BIBLIOS_INDEX }
        ),
        'Creating a new QueryBuilder object'
    );

    t::lib::Mocks::mock_preference( 'QueryAutoTruncate', 0 );

    my $res = $qb->clean_search_term('an=123');
    is( $res, 'koha-auth-number:123', 'equals sign replaced with colon' );

    $res = $qb->clean_search_term('"balanced quotes"');
    is( $res, '"balanced quotes"', 'balanced quotes returned correctly' );

    $res = $qb->clean_search_term('unbalanced quotes"');
    is( $res, 'unbalanced quotes ', 'unbalanced quotes removed' );

    $res = $qb->clean_search_term('"unbalanced "quotes"');
    is( $res, ' unbalanced  quotes ', 'unbalanced quotes removed' );

    $res = $qb->clean_search_term(':test query');
    is( $res, 'test query', 'remove colon at the start' );

    $res = $qb->clean_search_term('test query\:');
    is( $res, 'test query', 'remove colon at the end' );

    $res = $qb->clean_search_term('test : query');
    is( $res, 'test query', 'dangling colon removed' );

    $res = $qb->clean_search_term('test :: query');
    is( $res, 'test query', 'dangling double colon removed' );

    $res = $qb->clean_search_term('test "another : query"');
    is( $res, 'test "another : query"', 'quoted dangling colon not removed' );

    $res = $qb->clean_search_term('host-item:test:n');
    is( $res, 'host-item:test\:n', 'screen colons properly' );

    $res = $qb->clean_search_term('host-item:test:n:test:and more');
    is( $res, 'host-item:test\:n\:test\:and more', 'screen multiple colons properly' );

    $res = $qb->clean_search_term('host-item:te st:n');
    is( $res, 'host-item:te st:n', 'leave colons as they are' );

    $res = $qb->clean_search_term('test!');
    is( $res, 'test', 'remove exclamation sign at the end of the line' );

    $res = $qb->clean_search_term('test! and more');
    is( $res, 'test and more', 'remove exclamation sign at with space after it' );

    $res = $qb->clean_search_term('test! and more (and more!)');
    is( $res, 'test and more (and more)', 'remove exclamation sign followed by close parentheses' );

    $res = $qb->clean_search_term('!test');
    is( $res, '!test', 'exclamation sign left untouched' );

    $res = $qb->clean_search_term('test [123 TO 345]');
    is( $res, 'test [123 TO 345]', 'keep inculsive range untouched' );

    $res = $qb->clean_search_term('test [test TO TEST} [and] {123 TO 456]');
    is( $res, 'test [test TO TEST} \[and\] {123 TO 456]', 'keep exclusive range untouched' );

    $res = $qb->clean_search_term('test [test TO TEST} ["[and] {123 TO 456]" "[balanced]"]');
    is( $res, 'test [test TO TEST} \["[and] {123 TO 456]" "[balanced]"\]', 'keep exclusive range untouched' );

    $res = $qb->clean_search_term('test[]test TO TEST] [ {123 to 345}}');
    is( $res, 'test\[\]test TO TEST\] \[ \{123 to 345\}\}', 'screen all square and curly brackets' );

    t::lib::Mocks::mock_preference( 'QueryRegexEscapeOptions', 'escape' );

    $res = $qb->clean_search_term('test inside regexps /this [a-z]/ and \/not [a-z]\/ and that [a-z] [a TO z]');
    is(
        $res, 'test inside regexps \/this \[a-z\]\/ and \/not \[a-z\]\/ and that \[a-z\] [a TO z]',
        'behaviour with QueryRegexEscapeOptions set to "escape"'
    );

    t::lib::Mocks::mock_preference( 'QueryRegexEscapeOptions', 'dont_escape' );

    $res = $qb->clean_search_term(
        'test inside regexps /this [a-z]/ /this2 [a-z]/ [but] /this3 [a-z]/ and \/not [a-z]\/ and that [a-z] [a TO z]');
    is(
        $res,
        'test inside regexps /this [a-z]/ /this2 [a-z]/ \[but\] /this3 [a-z]/ and \/not \[a-z\]\/ and that \[a-z\] [a TO z]',
        'behaviour with QueryRegexEscapeOptions set to "dont_escape"'
    );

    $res = $qb->clean_search_term('ti:test AND kw:test');
    is(
        $res, 'title:test AND test',
        'ti converted to title, kw converted to empty string, dangling colon removed with space preserved'
    );

    $res = $qb->clean_search_term('kw:test');
    is( $res, 'test', 'kw converted to empty string, dangling colon is removed' );

    C4::Context->interface('opac');
    t::lib::Mocks::mock_preference( 'OpacElasticsearchEscapeCharacters', '' );
    $res = $qb->clean_search_term('Simple? query');
    is( $res, 'Simple? query', 'question mark not touched' );

    t::lib::Mocks::mock_preference( 'OpacElasticsearchEscapeCharacters', '?' );
    $res = $qb->clean_search_term('Simple? query');
    is( $res, 'Simple\? query', 'question mark escaped' );

    C4::Context->interface('intranet');
    t::lib::Mocks::mock_preference( 'ElasticsearchEscapeCharacters', '' );
    $res = $qb->clean_search_term('Simple? query');
    is( $res, 'Simple? query', 'question mark not touched' );

    t::lib::Mocks::mock_preference( 'ElasticsearchEscapeCharacters', '?#' );
    $res = $qb->clean_search_term('Simple?# query');
    is( $res, 'Simple\?\# query', 'question mark and hash escaped' );
};

subtest '_join_queries' => sub {
    plan tests => 6;

    my $params = {
        index => $Koha::SearchEngine::Elasticsearch::BIBLIOS_INDEX,
    };
    my $qb = Koha::SearchEngine::Elasticsearch::QueryBuilder->new($params);

    my $query;

    $query = $qb->_join_queries('foo');
    is( $query, 'foo', 'should work with a single param' );

    $query = $qb->_join_queries( undef, '', 'foo', '', undef );
    is( $query, 'foo', 'should ignore undef or empty queries' );

    $query = $qb->_join_queries( 'foo', 'bar' );
    is( $query, '(foo) AND (bar)', 'should join queries with an AND' );

    $query = $qb->_join_queries( 'homebranch:foo', 'onloan:false' );
    is( $query, '(homebranch:foo) AND (onloan:false)', 'should also work when field is specified' );

    $query = $qb->_join_queries( 'homebranch:foo', 'mc-itype:BOOK', 'mc-itype:EBOOK' );
    is( $query, '(homebranch:foo) AND itype:(BOOK OR EBOOK)', 'should join with OR when using an "mc-" field' );

    $query = $qb->_join_queries( 'homebranch:foo', 'mc-itype:BOOK', 'mc-itype:EBOOK', 'mc-location:SHELF' );
    is(
        $query, '(homebranch:foo) AND itype:(BOOK OR EBOOK) AND location:(SHELF)',
        'should join "mc-" parts with AND if not the same field'
    );
};

subtest '_create_query_string' => sub {
    plan tests => 2;

    my $params = {
        index => $Koha::SearchEngine::Elasticsearch::BIBLIOS_INDEX,
    };
    my $qb = Koha::SearchEngine::Elasticsearch::QueryBuilder->new($params);

    my @queries;
    my $normal_query = [
        {
            'operand'  => 'perl*',
            'operator' => undef
        }
    ];

    @queries = $qb->_create_query_string(@$normal_query);
    my $expect = ['(perl*)'];

    is( @queries, @$expect, 'expected search structure' );

    my $geo_query = [
        {
            'operator' => undef,
            'field'    => 'geolocation',
            'type'     => undef,
            'operand'  => 'lat:48.25* lng:16.35* distance:100km*'
        }
    ];

    @queries = $qb->_create_query_string(@$geo_query);
    my $expect_geo = [];
    is( @queries, @$expect_geo, 'expected geo search structure => empty normal search string' );

};

subtest '_build_item_filter_query() tests (Bug XXXXX)' => sub {
    plan tests => 12;

    my $qb = 'Koha::SearchEngine::Elasticsearch::QueryBuilder';

    my $nested = $qb->_build_item_filter_query(
        [
            { field => 'homebranch', value => 'CPL' },
            { field => 'onrequest',  value => JSON::true },
        ]
    );

    is_deeply(
        $nested,
        {
            nested => {
                path  => 'items',
                query => {
                    bool => {
                        filter => [
                            { term => { 'items.homebranch' => 'CPL' } },
                            { term => { 'items.onrequest'  => JSON::true } },
                        ]
                    }
                }
            }
        },
        'term filters are wrapped in a single bool inside one nested query (same-item coherence)'
    );

    my $geo = $qb->_build_item_filter_query(
        [ { field => 'home_geolocation', lat => 40.4168, lon => -3.7038, distance => '10km' } ] );

    is_deeply(
        $geo,
        {
            nested => {
                path  => 'items',
                query => {
                    bool => {
                        filter => [
                            {
                                geo_distance => {
                                    distance                 => '10km',
                                    'items.home_geolocation' => { lat => 40.4168, lon => -3.7038 },
                                }
                            }
                        ]
                    }
                }
            }
        },
        'a geo_distance proximity filter is built inside the nested query'
    );

    my $combined = $qb->_build_item_filter_query(
        [
            { field => 'holdingbranch',    value => 'MPL' },
            { field => 'home_geolocation', lat   => 1, lon => 2, distance => '5km' },
        ]
    );
    is( scalar @{ $combined->{nested}{query}{bool}{filter} }, 2, 'term and geo filters share the same nested bool' );

    # a multi-value library limit becomes a terms filter.
    my $terms = $qb->_build_item_filter_query( [ { field => 'homebranch', values => [ 'CPL', 'MPL' ] } ] );
    is_deeply(
        $terms->{nested}{query}{bool}{filter},
        [ { terms => { 'items.homebranch' => [ 'CPL', 'MPL' ] } } ],
        'a values entry becomes a terms filter on the same item'
    );

    # a "both branches" limit becomes a same-item should of two terms.
    my $both = $qb->_build_item_filter_query(
        [
            {
                should => [
                    { field => 'homebranch',    values => ['CPL'] },
                    { field => 'holdingbranch', values => ['CPL'] },
                ]
            }
        ]
    );
    is_deeply(
        $both->{nested}{query}{bool}{filter},
        [
            {
                bool => {
                    should => [
                        { terms => { 'items.homebranch'    => ['CPL'] } },
                        { terms => { 'items.holdingbranch' => ['CPL'] } },
                    ],
                    minimum_should_match => 1,
                }
            }
        ],
        'a should entry becomes a same-item bool disjunction'
    );

    # Several equality filters on the same field combine as an OR (terms), so a
    # record with items in different libraries matches "homebranch:CPL OR FFL".
    my $same_field = $qb->_build_item_filter_query(
        [
            { field => 'homebranch', value => 'CPL' },
            { field => 'homebranch', value => 'FFL' },
        ]
    );
    is_deeply(
        $same_field->{nested}{query}{bool}{filter},
        [ { terms => { 'items.homebranch' => [ 'CPL', 'FFL' ] } } ],
        'two filters on the same field collapse into a single OR-ing terms clause'
    );

    # Different fields stay AND-ed (one clause each) while the repeated field is
    # still merged, and the first-occurrence order of the fields is preserved.
    my $mixed = $qb->_build_item_filter_query(
        [
            { field => 'homebranch', value => 'CPL' },
            { field => 'available',  value => JSON::true },
            { field => 'homebranch', value => 'FFL' },
        ]
    );
    is_deeply(
        $mixed->{nested}{query}{bool}{filter},
        [
            { terms => { 'items.homebranch' => [ 'CPL', 'FFL' ] } },
            { term  => { 'items.available'  => JSON::true } },
        ],
        'same-field values merge while different fields stay separate, order preserved'
    );

    # a wildcard leaf (e.g. a call-number operand) is built verbatim and is
    # never merged with the term/terms slots.
    my $wildcard = $qb->_build_item_filter_query(
        [
            { field => 'callnumber', wildcard => '*ABC*' },
            { field => 'homebranch', value    => 'CPL' },
        ]
    );
    is_deeply(
        $wildcard->{nested}{query}{bool}{filter},
        [
            { wildcard => { 'items.callnumber' => { value => '*ABC*' } } },
            { term     => { 'items.homebranch' => 'CPL' } },
        ],
        'a wildcard leaf is built same-item alongside a term, unmerged'
    );

    # a range leaf (acquisition-date operand) is built on the date subfield.
    my $range = $qb->_build_item_filter_query(
        [ { field => 'dateaccessioned', range => { gte => '2020-01-01', lte => '2020-12-31' } } ] );
    is_deeply(
        $range->{nested}{query}{bool}{filter},
        [ { range => { 'items.dateaccessioned' => { gte => '2020-01-01', lte => '2020-12-31' } } } ],
        'a range leaf becomes a range clause on the same item'
    );

    # without want_inner_hits the nested carries no inner_hits.
    my $no_ih = $qb->_build_item_filter_query( [ { field => 'homebranch', value => 'CPL' } ] );
    ok( !exists $no_ih->{nested}{inner_hits}, 'no inner_hits requested by default' );

    my $no_ih2 =
        $qb->_build_item_filter_query( [ { field => 'homebranch', value => 'CPL' } ], { want_inner_hits => 0 } );
    ok( !exists $no_ih2->{nested}{inner_hits}, 'no inner_hits when want_inner_hits is false' );

    # with want_inner_hits the nested asks ES which items matched, limited
    # to items.itemnumber and capped at the matched-items window (50000, kept in
    # sync with index.max_inner_result_window in index_config.yaml).
    my $with_ih =
        $qb->_build_item_filter_query( [ { field => 'homebranch', value => 'CPL' } ], { want_inner_hits => 1 } );
    is_deeply(
        $with_ih->{nested}{inner_hits},
        {
            _source => ['items.itemnumber'],
            size    => 50000,
        },
        'want_inner_hits adds inner_hits over items.itemnumber capped at the window'
    );
};

subtest '_extract_item_filters() tests (Bug XXXXX)' => sub {
    plan tests => 11;

    my $qb = 'Koha::SearchEngine::Elasticsearch::QueryBuilder';

    my ( $item_filters, $remaining ) = $qb->_extract_item_filters(
        [
            'items.homebranch:CPL',
            'itype:BK',
            'items.onrequest:true',
            'items.available:true',
            'items.home_geolocation,geo_distance:40.4168,-3.7038,10km',
        ]
    );

    is_deeply( $remaining, ['itype:BK'], 'non-item limits are left untouched' );
    is( scalar @$item_filters, 4, 'four item limits are extracted' );
    is_deeply(
        $item_filters->[0], { field => 'homebranch', value => 'CPL' },
        'a term item limit is parsed'
    );
    is_deeply(
        $item_filters->[1], { field => 'onrequest', value => JSON::true },
        'a "true" value is coerced to a JSON boolean'
    );

    # the availability control emits items.available:true, which is routed
    # to the same nested channel as the library facet so they resolve on the
    # same item.
    is_deeply(
        $item_filters->[2], { field => 'available', value => JSON::true },
        'the items.available limit is parsed into the nested channel'
    );
    is_deeply(
        $item_filters->[3],
        { field => 'home_geolocation', lat => 40.4168, lon => -3.7038, distance => '10km' },
        'a geo_distance item limit is parsed'
    );

    # advanced-search item-field limits are routed to the nested channel.
    my ( $mc_filters, $mc_remaining ) = $qb->_extract_item_filters(
        [
            'mc-itype:CR',
            'mc-ccode:FIC',
            'mc-loc:SHELF',
            'loc:DISPLAY',
            'mc-itemtype:BK',
        ]
    );
    is_deeply(
        $mc_filters,
        [
            { field => 'itype',    value => 'CR' },
            { field => 'ccode',    value => 'FIC' },
            { field => 'location', value => 'SHELF' },
            { field => 'location', value => 'DISPLAY' },
        ],
        'mc-itype / mc-ccode / mc-loc / loc are routed to items.itype / ccode / location'
    );
    is_deeply(
        $mc_remaining, ['mc-itemtype:BK'],
        'mc-itemtype (record-level item type) is left flat'
    );

    # Quoted values have the surrounding quotes stripped.
    my ($quoted) = $qb->_extract_item_filters( ['mc-itype:"CR"'] );
    is_deeply( $quoted, [ { field => 'itype', value => 'CR' } ], 'surrounding quotes are stripped' );

    # The advanced search appends a ",phr" CCL modifier (mc-itype,phr:CR); it must
    # still be routed to the nested channel, with the modifier dropped.
    my ($phr) = $qb->_extract_item_filters( [ 'mc-itype,phr:CR', 'mc-loc,phr:SHELF' ] );
    is_deeply(
        $phr,
        [ { field => 'itype', value => 'CR' }, { field => 'location', value => 'SHELF' } ],
        'a ",phr" modifier on an item-field limit is tolerated and routed'
    );

    # the patron-facing availability control emits
    # items.available_for_patron:true, routed to the same nested channel as the
    # staff items.available, so it resolves same-item with the facets.
    my ($afp) = $qb->_extract_item_filters( ['items.available_for_patron:true'] );
    is_deeply(
        $afp, [ { field => 'available_for_patron', value => JSON::true } ],
        'the items.available_for_patron limit is parsed into the nested channel'
    );
};

subtest '_extract_item_filters() OPAC whitelist (Bug XXXXX)' => sub {
    plan tests => 7;

    my $qb = 'Koha::SearchEngine::Elasticsearch::QueryBuilder';

    my @allowed = (
        'items.homebranch:CPL',            'items.holdingbranch:CPL',
        'items.itype:BK',                  'items.location:SHELF',
        'items.ccode:FIC',                 'items.available:true',
        'items.available_for_patron:true', 'items.onrequest:false',
        'items.barcode:12345',             'items.callnumber:ABC',
        'items.dateaccessioned:2020-01-01',
        'items.home_geolocation,geo_distance:40.4168,-3.7038,10km',
        'items.holding_geolocation,geo_distance:40.4168,-3.7038,10km',
    );
    my ($opac_filters) = $qb->_extract_item_filters( \@allowed, { is_opac => 1 } );
    is( scalar @$opac_filters, scalar @allowed, 'the whitelisted item limits are kept in the OPAC' );

    my @hidden_probes = (
        'items.lost:1',
        'items.withdrawn:1',
        'items.hidden_in_opac_by_preferences:true',
        'items.hidden_in_opac_custom:true',
    );
    my ( $probe_filters, $probe_remaining );
    warnings_like {
        ( $probe_filters, $probe_remaining ) =
            $qb->_extract_item_filters( [ @hidden_probes, 'itype:BK' ], { is_opac => 1 } );
    }
    [ map { qr/Ignoring OPAC limit '\Q$_\E'/ } @hidden_probes ],
        'a warning is issued for each dropped limit';
    is_deeply( $probe_filters,   [],           'item limits outside the whitelist are dropped in the OPAC' );
    is_deeply( $probe_remaining, ['itype:BK'], 'and do not fall through to the flat limits' );

    my $geo_filters;
    warning_like {
        ($geo_filters) = $qb->_extract_item_filters(
            ['items.itype,geo_distance:40.4168,-3.7038,10km'],
            { is_opac => 1 }
        );
    }
    qr/Ignoring OPAC limit/, 'a geo_distance limit on a non-geo field is dropped with a warning';
    is_deeply( $geo_filters, [], 'and is not turned into a filter' );

    my ($staff_filters) = $qb->_extract_item_filters( \@hidden_probes );
    is( scalar @$staff_filters, scalar @hidden_probes, 'the staff interface accepts any item field' );
};

subtest '_item_operand_to_filter() tests (Bug XXXXX)' => sub {
    plan tests => 10;

    my $qb = 'Koha::SearchEngine::Elasticsearch::QueryBuilder';

    is_deeply(
        $qb->_item_operand_to_filter( { subfield => 'barcode', kind => 'term' }, '12345' ),
        { field => 'barcode', value => '12345' },
        'a term operand becomes a plain value filter'
    );

    is_deeply(
        $qb->_item_operand_to_filter( { subfield => 'callnumber', kind => 'wildcard' }, 'ABC' ),
        { field => 'callnumber', wildcard => '*ABC*' },
        'a wildcard operand is wrapped with leading/trailing wildcards'
    );

    is_deeply(
        $qb->_item_operand_to_filter( { subfield => 'callnumber', kind => 'wildcard' }, '"QA76.9 B45"' ),
        { field => 'callnumber', wildcard => '*QA76.9 B45*' },
        'double quotes wrapping a wildcard operand are removed'
    );

    is_deeply(
        $qb->_item_operand_to_filter( { subfield => 'barcode', kind => 'term' }, '"12345"' ),
        { field => 'barcode', value => '12345' },
        'double quotes wrapping a term operand are removed'
    );

    is(
        $qb->_item_operand_to_filter( { subfield => 'barcode', kind => 'term' }, '""' ), undef,
        'an operand made only of quotes is empty'
    );

    is_deeply(
        $qb->_item_operand_to_filter( { subfield => 'callnumber', kind => 'wildcard' }, 'A*B' ),
        { field => 'callnumber', wildcard => '*A\\*B*' },
        'wildcard metacharacters in the value are escaped'
    );

    is_deeply(
        $qb->_item_operand_to_filter( { subfield => 'dateaccessioned', kind => 'range' }, '2020-05-01' ),
        { field => 'dateaccessioned', range => { gte => '2020-05-01', lte => '2020-05-01' } },
        'a single date becomes a one-day range'
    );

    is_deeply(
        $qb->_item_operand_to_filter( { subfield => 'dateaccessioned', kind => 'range' }, '2020-01-01 - 2020-12-31' ),
        { field => 'dateaccessioned', range => { gte => '2020-01-01', lte => '2020-12-31' } },
        'a "from - to" value becomes a bounded range'
    );

    is_deeply(
        $qb->_item_operand_to_filter( { subfield => 'dateaccessioned', kind => 'range' }, '2020-01-01 - *' ),
        { field => 'dateaccessioned', range => { gte => '2020-01-01' } },
        'an open upper bound is omitted'
    );

    is(
        $qb->_item_operand_to_filter( { subfield => 'barcode', kind => 'term' }, '' ),
        undef, 'an empty operand yields no filter'
    );
};

subtest '_build_item_facet_aggregation() tests (Bug XXXXX)' => sub {
    plan tests => 3;

    my $qb = 'Koha::SearchEngine::Elasticsearch::QueryBuilder';

    is_deeply(
        $qb->_build_item_facet_aggregation( 'homebranch', 30 ),
        {
            nested => { path => 'items' },
            aggs   => {
                item_filter => {
                    filter => { bool => { filter => [] } },
                    aggs   => {
                        homebranch => {
                            terms => { field        => 'items.homebranch', size => 30 },
                            aggs  => { record_count => { reverse_nested => {} } },
                        },
                    },
                },
            },
        },
        'item facet wraps the reverse_nested terms in an empty item_filter (no active filters)'
    );

    is_deeply(
        $qb->_build_item_facet_aggregation( 'homebranch', 30, [] ),
        $qb->_build_item_facet_aggregation( 'homebranch', 30 ),
        'an empty clause list is equivalent to passing none (match-all, counts unchanged)'
    );

    my @clauses = ( { term => { 'items.itype' => 'BK' } } );
    is_deeply(
        $qb->_build_item_facet_aggregation( 'homebranch', 30, \@clauses ),
        {
            nested => { path => 'items' },
            aggs   => {
                item_filter => {
                    filter => { bool => { filter => \@clauses } },
                    aggs   => {
                        homebranch => {
                            terms => { field        => 'items.homebranch', size => 30 },
                            aggs  => { record_count => { reverse_nested => {} } },
                        },
                    },
                },
            },
        },
        'active item-filter clauses are applied inside the item_filter sub-agg (same-item counts)'
    );
};

1;
