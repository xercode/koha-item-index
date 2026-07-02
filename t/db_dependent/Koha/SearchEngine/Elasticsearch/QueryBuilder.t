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

use C4::Context;
use Test::Exception;
use Test::Warn;
use t::lib::Mocks;
use t::lib::TestBuilder;
use Test::NoWarnings;
use Test::More tests => 16;

use List::Util qw( all );

use Koha::Database;
use Koha::SearchEngine::Elasticsearch::QueryBuilder;
use Koha::SearchFilters;

my $schema = Koha::Database->new->schema;
$schema->storage->txn_begin;

my $se = Test::MockModule->new('Koha::SearchEngine::Elasticsearch');
$se->mock(
    'get_elasticsearch_mappings',
    sub {
        my ($self) = @_;

        my %all_mappings;

        my $mappings = {
            properties => {
                title       => { type => 'text' },
                title__sort => { type => 'text' },
                subject     => {
                    type  => 'text',
                    facet => 1
                },
                'subject-heading-thesaurus' => {
                    type  => 'text',
                    facet => 1
                },
                'subject-heading-thesaurus-conventions' => { type => 'text' },
                itemnumber                              => { type => 'integer' },
                sortablenumber                          => { type => 'integer' },
                sortablenumber__sort                    => { type => 'integer' },
                heading                                 => { type => 'text' },
                'heading-main'                          => { type => 'text' },
                heading__sort                           => { type => 'text' },
                match                                   => { type => 'text' },
                'match-heading'                         => { type => 'text' },
                'match-heading-see-from'                => { type => 'text' },
            }
        };
        $all_mappings{ $self->index } = $mappings;

        my $sort_fields = {
            $self->index => {
                title          => 1,
                subject        => 0,
                itemnumber     => 0,
                sortablenumber => 1,
                mainentry      => 1
            }
        };
        $self->sort_fields( $sort_fields->{ $self->index } );

        return $all_mappings{ $self->index };
    }
);

subtest 'build_authorities_query_compat() tests' => sub {

    plan tests => 83;

    my $qb;

    ok(
        $qb = Koha::SearchEngine::Elasticsearch::QueryBuilder->new( { 'index' => 'authorities' } ),
        'Creating new query builder object for authorities'
    );

    my $koha_name   = 'any';
    my $search_term = 'a';
    my $query       = $qb->build_authorities_query_compat(
        [$koha_name], undef, undef, ['contains'], [$search_term], 'AUTH_TYPE',
        'asc'
    );
    ok( !defined $query->{query}->{bool}->{should}, "Should query not used if 'and_or' not passed" );
    ok( defined $query->{query}->{bool}->{must},    "Must query used if 'and_or' not passed" );
    is( $query->{query}->{bool}->{must}[0]->{query_string}->{query}, "a*" );
    $query = $qb->build_authorities_query_compat(
        [$koha_name], ['and'], undef, ['contains'], [$search_term], 'AUTH_TYPE',
        'asc'
    );
    ok( !defined $query->{query}->{bool}->{should}, "Should query not used when 'and_or' passed 'and'" );
    ok( defined $query->{query}->{bool}->{must},    "Must query used when 'and_or' passed 'and'" );
    is( $query->{query}->{bool}->{must}[0]->{query_string}->{query}, "a*" );
    $query = $qb->build_authorities_query_compat(
        [$koha_name], ['or'], undef, ['contains'], [$search_term], 'AUTH_TYPE',
        'asc'
    );
    ok( defined $query->{query}->{bool}->{should}, "Should query used if 'and_or' passed 'or'" );
    ok( defined $query->{query}->{bool}->{should}, "Must query not used if 'and_or' passed 'or'" );
    is( $query->{query}->{bool}->{should}[0]->{query_string}->{query}, "a*" );

    my $koha_to_index_name = $Koha::SearchEngine::Elasticsearch::QueryBuilder::koha_to_index_name;
    $search_term = 'a';
    foreach my $koha_name ( keys %{$koha_to_index_name} ) {
        my $query = $qb->build_authorities_query_compat(
            [$koha_name], undef, undef, ['contains'], [$search_term], 'AUTH_TYPE',
            'asc'
        );
        if ( $koha_name eq 'all' || $koha_name eq 'any' ) {
            is(
                $query->{query}->{bool}->{must}[0]->{query_string}->{query},
                "a*"
            );
        } else {
            is(
                $query->{query}->{bool}->{must}[0]->{query_string}->{query},
                "a*"
            );
        }
        is(
            $query->{query}->{bool}->{must}[0]->{query_string}->{analyze_wildcard}, JSON::true,
            'Set analyze_wildcard true'
        );
        is( $query->{query}->{bool}->{must}[0]->{query_string}->{lenient}, JSON::true, 'Set lenient true' );
    }

    $search_term = 'Donald Duck';
    foreach my $koha_name ( keys %{$koha_to_index_name} ) {
        my $query = $qb->build_authorities_query_compat(
            [$koha_name], undef, undef, ['contains'], [$search_term], 'AUTH_TYPE',
            'asc'
        );
        is( $query->{query}->{bool}->{must}[0]->{query_string}->{query}, "(Donald*) AND (Duck*)" );
        if ( $koha_name eq 'all' || $koha_name eq 'any' ) {
            isa_ok( $query->{query}->{bool}->{must}[0]->{query_string}->{fields}, 'ARRAY' );
        } else {
            is(
                $query->{query}->{bool}->{must}[0]->{query_string}->{default_field},
                $koha_to_index_name->{$koha_name}
            );
        }
    }

    foreach my $koha_name ( keys %{$koha_to_index_name} ) {
        my $query = $qb->build_authorities_query_compat(
            [$koha_name], undef, undef, ['is'], [$search_term], 'AUTH_TYPE',
            'asc'
        );
        if ( $koha_name eq 'all' || $koha_name eq 'any' ) {
            is(
                $query->{query}->{bool}->{must}[0]->{multi_match}->{query},
                "Donald Duck"
            );
            my $all_matches = all { /\.ci_raw$/ } @{ $query->{query}->{bool}->{must}[0]->{multi_match}->{fields} };
            ok( $all_matches, 'Correct fields parameter for "is" query in "any" or "all"' );
        } else {
            is(
                $query->{query}->{bool}->{must}[0]->{term}->{ $koha_to_index_name->{$koha_name} . ".ci_raw" },
                "Donald Duck"
            );
        }
    }

    foreach my $koha_name ( keys %{$koha_to_index_name} ) {
        my $query = $qb->build_authorities_query_compat(
            [$koha_name], undef, undef, ['start'], [$search_term], 'AUTH_TYPE',
            'asc'
        );
        if ( $koha_name eq 'all' || $koha_name eq 'any' ) {
            my $all_matches =
                all { ( %{ $_->{prefix} } )[0] =~ /\.ci_raw$/ && ( %{ $_->{prefix} } )[1] eq "Donald Duck" }
                @{ $query->{query}->{bool}->{must}[0]->{bool}->{should} };
            ok( $all_matches, "Correct multiple prefix query" );
        } else {
            is(
                $query->{query}->{bool}->{must}[0]->{prefix}->{ $koha_to_index_name->{$koha_name} . ".ci_raw" },
                "Donald Duck"
            );
        }
    }

    # Sorting
    $query = $qb->build_authorities_query_compat(
        ['mainentry'], undef, undef, ['start'], [$search_term], 'AUTH_TYPE',
        'HeadingAsc'
    );
    is_deeply(
        $query->{sort},
        [ { 'heading__sort' => 'asc' } ],
        "ascending sort parameter properly formed"
    );
    $query = $qb->build_authorities_query_compat(
        ['mainentry'], undef, undef, ['start'], [$search_term], 'AUTH_TYPE',
        'HeadingDsc'
    );
    is_deeply(
        $query->{sort},
        [ { 'heading__sort' => 'desc' } ],
        "descending sort parameter properly formed"
    );

    # Authorities type
    $query = $qb->build_authorities_query_compat(
        ['mainentry'], undef, undef, ['contains'], [$search_term], 'AUTH_TYPE',
        'asc'
    );
    is_deeply(
        $query->{query}->{bool}->{filter},
        { term => { 'authtype.raw' => 'AUTH_TYPE' } },
        "authorities type code is used as filter"
    );

    # Authorities marclist check
    warning_like {
        $query = $qb->build_authorities_query_compat(
            [ 'tomas', 'mainentry' ],       undef,       undef, ['contains'],
            [ $search_term, $search_term ], 'AUTH_TYPE', 'asc'
        )
    }
    qr/Unknown search field tomas/,
        "Warning for unknown field in marclist";
    is_deeply(
        $query->{query}->{bool}->{must}[0]->{query_string}->{default_field},
        'tomas',
        "If no mapping for marclist the index is passed through as defined"
    );
    is_deeply(
        $query->{query}->{bool}->{must}[1]->{query_string}{default_field},
        'heading',
        "If mapping found for marclist the index is passed through converted"
    );

    # Thesaurus value mapping delegates to Koha::Authority (bug 31925)
    $query = $qb->build_authorities_query_compat(
        ['thesaurus'], undef, undef, ['contains'], ['lcsh'], 'AUTH_TYPE',
        'asc'
    );
    is(
        $query->{query}->{bool}->{must}[0]->{query_string}->{query}, 'a*',
        "thesaurus value 'lcsh' is still translated to 008/11 code 'a'"
    );
    $query = $qb->build_authorities_query_compat(
        ['thesaurus'], undef, undef, ['contains'], ['mesh'], 'AUTH_TYPE',
        'asc'
    );
    is(
        $query->{query}->{bool}->{must}[0]->{query_string}->{query}, 'c*',
        "thesaurus value 'mesh' is still translated to 008/11 code 'c'"
    );

};

subtest 'build_query tests' => sub {
    plan tests => 73;

    my $qb;

    ok(
        $qb = Koha::SearchEngine::Elasticsearch::QueryBuilder->new( { 'index' => 'biblios' } ),
        'Creating new query builder object for biblios'
    );

    my @sort_by     = 'title_asc';
    my @sort_params = $qb->_convert_sort_fields(@sort_by);
    my %options;
    $options{sort} = \@sort_params;
    my $query = $qb->build_query( 'test', %options );

    is_deeply(
        $query->{sort},
        [ { 'title__sort' => { 'order' => 'asc' } }, { 'local-number__sort' => { 'order' => 'desc' } } ],
        "sort parameter properly formed"
    );

    t::lib::Mocks::mock_preference( 'FacetMaxCount',        '37' );
    t::lib::Mocks::mock_preference( 'DisplayLibraryFacets', 'both' );
    $query = $qb->build_query( 'test', %options );

    # ccode, homebranch and holdingbranch are item facets (Bug XXXXX): they
    # aggregate over the nested items object and, so their bucket counts respect
    # the active item filters (own fork fix), the terms aggregation is wrapped in
    # an item_filter sub-aggregation. The terms size therefore lives two levels
    # down: under item_filter, then under the aggregation named after the facet.
    ok(
        defined $query->{aggregations}{ccode}{aggs}{item_filter}{aggs}{ccode}{terms}{size},
        'we need to ask for a size or we get only 5 facet'
    );
    is(
        $query->{aggregations}{ccode}{aggs}{item_filter}{aggs}{ccode}{terms}{size}, 37,
        'we ask for the size as defined by the syspref FacetMaxCount'
    );
    is(
        $query->{aggregations}{homebranch}{aggs}{item_filter}{aggs}{homebranch}{terms}{size}, 37,
        'we ask for the size as defined by the syspref FacetMaxCount for homebranch'
    );
    is(
        $query->{aggregations}{holdingbranch}{aggs}{item_filter}{aggs}{holdingbranch}{terms}{size}, 37,
        'we ask for the size as defined by the syspref FacetMaxCount for holdingbranch'
    );

    $options{skip_facets} = 1;
    $query = $qb->build_query( 'test', %options );
    ok( !defined $query->{aggregations}, 'Skipping facets means we do not have aggregations in the the query' );

    $query = $qb->build_query( 'test', () );

    is_deeply(
        $query->{sort},
        [
            { '_score'             => { 'order' => 'desc' } },
            { 'local-number__sort' => { 'order' => 'desc' } }
        ],
        "sort parameter properly formed if no sort passed"
    );

    t::lib::Mocks::mock_preference( 'QueryAutoTruncate', '' );

    ( undef, $query ) = $qb->build_query_compat( undef, ['donald duck'] );
    is(
        $query->{query}{bool}{must}[0]{query_string}{query},
        "(donald duck)",
        "query not altered if QueryAutoTruncate disabled"
    );
    ok( defined $query->{aggregations}, 'Aggregations generated normally' );
    ( undef, $query ) =
        $qb->build_query_compat( undef, ['donald duck'], undef, undef, undef, undef, undef, { skip_facets => 1 } );
    ok( !defined $query->{aggregations}, 'Aggregations generated normally' );

    ( undef, $query ) = $qb->build_query_compat( undef, ['donald duck'], ['kw,phr'] );
    is(
        $query->{query}{bool}{must}[0]{query_string}{query},
        '("donald duck")',
        "keyword as phrase correctly quotes search term and strips index"
    );

    ( undef, $query ) = $qb->build_query_compat( undef, ['donald duck'], ['title'] );
    is(
        $query->{query}{bool}{must}[0]{query_string}{query},
        '(title:(donald duck))',
        'multiple words in a query term are enclosed in parenthesis'
    );

    ( undef, $query ) = $qb->build_query_compat( ['AND'], [ 'donald duck', 'disney' ], [ 'title', 'author' ] );
    is(
        $query->{query}{bool}{must}[0]{query_string}{query},
        '(title:(donald duck)) AND (author:disney)',
        'multiple query terms are enclosed in parenthesis while a single one is not'
    );

    my ( $simple_query, $query_cgi, $query_desc );
    ( undef, $query, $simple_query, $query_cgi, $query_desc ) =
        $qb->build_query_compat( undef, [ '"donald duck"', 'walt disney' ], [ 'ti', 'au' ] );
    is( $query_cgi,  'idx=ti&q=%22donald%20duck%22&idx=au&q=walt%20disney', 'query cgi ok for multiterm query' );
    is( $query_desc, '(title:("donald duck")) (author:(walt disney))',      'query desc ok for multiterm query' );

    # Test whole_record and weighted_fields parameters in query_cgi
    ( undef, $query, $simple_query, $query_cgi, $query_desc ) = $qb->build_query_compat(
        undef, ['test'], ['kw'], undef, undef, undef, undef,
        { whole_record => 1, weighted_fields => 1, weight_search_submitted => 1 }
    );
    is(
        $query_cgi, 'idx=kw&q=test&weight_search=1&weight_search_submitted=1&whole_record=1',
        'query_cgi includes whole_record, weight_search and weight_search_submitted parameters'
    );

    ( undef, $query, $simple_query, $query_cgi, $query_desc ) = $qb->build_query_compat(
        undef, ['test'], ['kw'], undef, undef, undef, undef,
        { whole_record => 1 }
    );
    is( $query_cgi, 'idx=kw&q=test&whole_record=1', 'query_cgi includes whole_record parameter only' );

    ( undef, $query, $simple_query, $query_cgi, $query_desc ) = $qb->build_query_compat(
        undef, ['test'], ['kw'], undef, undef, undef, undef,
        { weighted_fields => 1, weight_search_submitted => 1 }
    );
    is(
        $query_cgi, 'idx=kw&q=test&weight_search=1&weight_search_submitted=1',
        'query_cgi includes weight_search and weight_search_submitted parameters only'
    );

    ( undef, $query ) = $qb->build_query_compat( undef, ['2019'], ['yr,st-year'] );
    is(
        $query->{query}{bool}{must}[0]{query_string}{query},
        '(date-of-publication:2019)',
        'Year in an st-year search is handled properly'
    );

    ( undef, $query ) = $qb->build_query_compat( undef, ['2018-2019'], ['yr,st-year'] );
    is(
        $query->{query}{bool}{must}[0]{query_string}{query},
        '(date-of-publication:[2018 TO 2019])',
        'Year range in an st-year search is handled properly'
    );

    ( undef, $query ) = $qb->build_query_compat( undef, ['-2019'], ['yr,st-year'] );
    is(
        $query->{query}{bool}{must}[0]{query_string}{query},
        '(date-of-publication:[* TO 2019])',
        'Open start year in year range of an st-year search is handled properly'
    );

    ( undef, $query ) = $qb->build_query_compat( undef, ['2019-'], ['yr,st-year'] );
    is(
        $query->{query}{bool}{must}[0]{query_string}{query},
        '(date-of-publication:[2019 TO *])',
        'Open end year in year range of an st-year search is handled properly'
    );

    ( undef, $query ) = $qb->build_query_compat( undef, ['2019-'], ['yr,st-year'], ['yr,st-numeric=-2019'] );
    is(
        $query->{query}{bool}{must}[0]{query_string}{query},
        '(date-of-publication:[2019 TO *]) AND date-of-publication:[* TO 2019]',
        'Open end year in year range of an st-year search is handled properly'
    );

    ( undef, $query ) = $qb->build_query_compat(
        undef, ['2019-'], ['yr,st-year'],
        [ 'yr,st-numeric:-2019', 'yr,st-numeric:2005', 'yr,st-numeric:1984-2022' ]
    );
    is(
        $query->{query}{bool}{must}[0]{query_string}{query},
        '(date-of-publication:[2019 TO *]) AND (date-of-publication:[* TO 2019]) AND (date-of-publication:2005) AND (date-of-publication:[1984 TO 2022])',
        'Limit on year search is handled properly when colon used'
    );

    # Enable auto-truncation
    t::lib::Mocks::mock_preference( 'QueryAutoTruncate', '1' );

    ( undef, $query ) = $qb->build_query_compat( undef, ['donald duck'] );
    is(
        $query->{query}{bool}{must}[0]{query_string}{query},
        "(donald* duck*)",
        "simple query is auto truncated when QueryAutoTruncate enabled"
    );

    # Ensure reserved words are not truncated
    ( undef, $query ) = $qb->build_query_compat(
        undef,
        ['donald or duck and mickey not mouse']
    );
    is(
        $query->{query}{bool}{must}[0]{query_string}{query},
        "(donald* or duck* and mickey* not mouse*)",
        "reserved words are not affected by QueryAutoTruncate"
    );

    ( undef, $query ) = $qb->build_query_compat( undef, ['donald* duck*'] );
    is(
        $query->{query}{bool}{must}[0]{query_string}{query},
        "(donald* duck*)",
        "query with '*' is unaltered when QueryAutoTruncate is enabled"
    );

    ( undef, $query ) = $qb->build_query_compat( undef, ['donald duck and the mouse'] );
    is(
        $query->{query}{bool}{must}[0]{query_string}{query},
        "(donald* duck* and the* mouse*)",
        "individual words are all truncated and stopwords ignored"
    );

    ( undef, $query ) = $qb->build_query_compat( undef, ['*'] );
    is(
        $query->{query}{bool}{must}[0]{query_string}{query},
        "(*)",
        "query of just '*' is unaltered when QueryAutoTruncate is enabled"
    );

    ( undef, $query ) = $qb->build_query_compat( undef, ['"donald duck"'], undef, ['available'] );
    is(
        $query->{query}{bool}{must}[0]{query_string}{query},
        '("donald duck") AND available:true',
        "query with quotes is unaltered when QueryAutoTruncate is enabled"
    );

    ( undef, $query ) = $qb->build_query_compat( undef, ['"donald duck" and "the mouse"'] );
    is(
        $query->{query}{bool}{must}[0]{query_string}{query},
        '("donald duck" and "the mouse")',
        "all quoted strings are unaltered if more than one in query"
    );

    # Reset ElasticsearchPreventAutoTruncate syspref
    t::lib::Mocks::mock_preference( 'ElasticsearchPreventAutoTruncate', '' );

    ( undef, $query ) = $qb->build_query_compat( undef, ['barcode:123456'] );
    is(
        $query->{query}{bool}{must}[0]{query_string}{query},
        '(barcode:123456*)',
        "query of specific field is truncated"
    );

    ( undef, $query ) = $qb->build_query_compat( undef, ['Personal-name:"donald"'] );
    is(
        $query->{query}{bool}{must}[0]{query_string}{query},
        '(personal-name:"donald")',
        "query of specific field including hyphen and quoted is not truncated, field name is converted to lower case"
    );

    ( undef, $query ) = $qb->build_query_compat( undef, ['Personal-name:donald'] );
    is(
        $query->{query}{bool}{must}[0]{query_string}{query},
        '(personal-name:donald*)',
        "query of specific field including hyphen and not quoted is truncated, field name is converted to lower case"
    );

    ( undef, $query ) = $qb->build_query_compat( undef, ['Personal-name.raw:donald'] );
    is(
        $query->{query}{bool}{must}[0]{query_string}{query},
        '(personal-name.raw:donald*)',
        "query of specific field including period and not quoted is truncated, field name is converted to lower case"
    );

    ( undef, $query ) = $qb->build_query_compat( undef, ['Personal-name.raw:"donald"'] );
    is(
        $query->{query}{bool}{must}[0]{query_string}{query},
        '(personal-name.raw:"donald")',
        "query of specific field including period and quoted is not truncated, field name is converted to lower case"
    );

    # Set ElasticsearchPreventAutoTruncate syspref
    t::lib::Mocks::mock_preference( 'ElasticsearchPreventAutoTruncate', 'barcode' );

    ( undef, $query ) = $qb->build_query_compat( undef, ['barcode:123456'] );
    is(
        $query->{query}{bool}{must}[0]{query_string}{query},
        '(barcode:123456)',
        "query of specific field excluded by ElasticsearchPreventAutoTruncate is not truncated"
    );

    ( undef, $query ) = $qb->build_query_compat( undef, ['Local-number:123456'] );
    is(
        $query->{query}{bool}{must}[0]{query_string}{query},
        '(local-number:123456)',
        "query of identifier is not truncated even if QueryAutoTruncate is set"
    );

    ( undef, $query ) = $qb->build_query_compat( undef, ['onloan:true'] );
    is(
        $query->{query}{bool}{must}[0]{query_string}{query},
        '(onloan:true)',
        "query of boolean type field is not truncated even if QueryAutoTruncate is set"
    );

    subtest 'removal of punctuation surrounded by spaces when autotruncate enabled' => sub {
        plan tests => 7;
        t::lib::Mocks::mock_preference( 'QueryAutoTruncate',       '1' );
        t::lib::Mocks::mock_preference( 'QueryRegexEscapeOptions', 'escape' );
        ( undef, $query ) = $qb->build_query_compat(
            undef,
            ['First title ; subtitle : some & subtitle / Authors Name. Second title ; Third title / Second Author']
        );
        is(
            $query->{query}{bool}{must}[0]{query_string}{query},
            '(First* title* subtitle* some* subtitle* Authors* Name. Second* title* Third* title* Second* Author*)',
            "ISBD punctuation and problematic characters surrounded by spaces properly removed"
        );

        t::lib::Mocks::mock_preference( 'QueryRegexEscapeOptions', 'dont_escape' );
        ( undef, $query ) = $qb->build_query_compat(
            undef,
            ['First title ; subtitle : some & subtitle / Authors Name. Second title ; Third title / Second Author']
        );
        is(
            $query->{query}{bool}{must}[0]{query_string}{query},
            '(First* title* subtitle* some* subtitle* / Authors* Name. Second* title* ; Third* title* / Second* Author*)',
            "ISBD punctuation and problematic characters surrounded by spaces properly removed, RE saved"
        );
        ( undef, $query ) =
            $qb->build_query_compat( undef, ['Lorem / ipsum dolor / sit ; / amet'] );
        is(
            $query->{query}{bool}{must}[0]{query_string}{query},
            '(Lorem* / ipsum* dolor* / sit* amet*)',
            "RE saved, last odd unescaped slash preceded by a semicolon removed"
        );

        t::lib::Mocks::mock_preference( 'QueryRegexEscapeOptions', 'escape' );
        ( undef, $query ) =
            $qb->build_query_compat( undef, ['Lorem \/ ipsum dolor \/ sit ; \/ amet'] );
        is(
            $query->{query}{bool}{must}[0]{query_string}{query},
            '(Lorem* ipsum* dolor* sit* amet*)',
            "Escaped slashes (also preceded by another punctuation followed by a space) removed"
        );
        ( undef, $query ) =
            $qb->build_query_compat( undef, ['comma , period . equal = hyphen - slash / escaped_slash \/'] );
        is(
            $query->{query}{bool}{must}[0]{query_string}{query},
            '(comma* period* equal* hyphen* slash* escaped_slash* \/)',
            "Other problematic characters surrounded by spaces properly removed"
        );

        ( undef, $query ) =
            $qb->build_query_compat( undef, [' &;,:=-/ // \/\/ /&&&==&&  ::-:: '] );
        is(
            $query->{query}{bool}{must}[0]{query_string}{query},
            '()',
            "Repeated problematic characters surrounded by spaces removed"
        );

        ( undef, $query ) = $qb->build_query_compat(
            undef,
            [
                '&amp amp& semicolon; ;colonsemi full: :full comma, ,comma dot. .dot =equal equal= hyphen- -hypen slash\/ \/slash'
            ]
        );
        is(
            $query->{query}{bool}{must}[0]{query_string}{query},
            '(&amp* amp& semicolon; ;colonsemi* full* full* comma, ,comma* dot. .dot* equal* equal* hyphen- -hypen* slash\/ \/slash*)',
            "ISBD punctuation and problematic characters not removed when not surrounded by spaces."
        );

        # Note above: semicolons and equals removed asthose are search field indicators - terms ending in punctuation
        # are not truncated.
        # Note that (colons/equal signs)/spaces glued to words are not removed by the feature under test but before.
    };

    # Reset SearchCancelledAndInvalidISBNandISSN syspref
    t::lib::Mocks::mock_preference( 'SearchCancelledAndInvalidISBNandISSN', '0' );

    ( undef, $query ) = $qb->build_query_compat( undef, ['nb:"9780141930848"'] );
    is(
        $query->{query}{bool}{must}[0]{query_string}{query},
        '(isbn:"9780141930848")',
        "nb query transformed into isbn search field"
    );

    # Set SearchCancelledAndInvalidISBNandISSN syspref
    t::lib::Mocks::mock_preference( 'SearchCancelledAndInvalidISBNandISSN', '1' );

    ( undef, $query ) = $qb->build_query_compat( undef, ['nb:"9780141930848"'] );
    is(
        $query->{query}{bool}{must}[0]{query_string}{query},
        '(isbn-all:"9780141930848")',
        "nb query transformed into isbn-all search field"
    );

    ( undef, $query ) = $qb->build_query_compat( undef, ['nb:"9780141930848" ns:"1089-6891"'] );
    is(
        $query->{query}{bool}{must}[0]{query_string}{query},
        '(isbn-all:"9780141930848" issn-all:"1089-6891")',
        "nb and ns query transformed into isbn-all and issn-all search field"
    );

    ( undef, $query ) = $qb->build_query_compat( undef, ['J.R.R'] );
    is(
        $query->{query}{bool}{must}[0]{query_string}{query},
        '(J.R.R*)',
        "query including period is truncated but not split at periods"
    );

    ( undef, $query ) = $qb->build_query_compat( undef, ['title:"donald duck"'] );
    is(
        $query->{query}{bool}{must}[0]{query_string}{query},
        '(title:"donald duck")',
        "query of specific field is not truncated when surrounded by quotes"
    );

    ( undef, $query ) = $qb->build_query_compat( undef, ['donald duck'], ['title'] );
    is(
        $query->{query}{bool}{must}[0]{query_string}{query},
        '(title:(donald* duck*))',
        'words of a multi-word term are properly truncated'
    );

    ( undef, $query ) = $qb->build_query_compat( ['AND'], [ 'donald duck', 'disney' ], [ 'title', 'author' ] );
    is(
        $query->{query}{bool}{must}[0]{query_string}{query},
        '(title:(donald* duck*)) AND (author:disney*)',
        'words of a multi-word term and single-word term are properly truncated'
    );

    ( undef, $query ) =
        $qb->build_query_compat( undef, ['title:"donald duck"'], undef, undef, undef, undef, undef, { suppress => 1 } );
    is(
        $query->{query}{bool}{must}[0]{query_string}{query},
        '(title:"donald duck") AND suppress:false',
        "query of specific field is added AND suppress:false"
    );

    ( undef, $query, $simple_query, $query_cgi, $query_desc ) =
        $qb->build_query_compat( undef, ['title:"donald duck"'], undef, undef, undef, undef, undef, { suppress => 0 } );
    is(
        $query->{query}{bool}{must}[0]{query_string}{query},
        '(title:"donald duck")',
        "query of specific field is not added AND suppress:0"
    );

    ( undef, $query ) =
        $qb->build_query_compat( ['AND'], ['title:"donald duck"'], undef, ['author:Dillinger Escaplan'] );
    is(
        $query->{query}{bool}{must}[0]{query_string}{query},
        '(title:"donald duck") AND author:("Dillinger Escaplan")',
        "Simple query with limit term quoted in parentheses"
    );

    ( undef, $query ) = $qb->build_query_compat(
        ['AND'], ['title:"donald duck"'], undef,
        [ 'author:Dillinger Escaplan', 'itype:BOOK' ]
    );
    is(
        $query->{query}{bool}{must}[0]{query_string}{query},
        '(title:"donald duck") AND (author:("Dillinger Escaplan")) AND (itype:("BOOK"))',
        "Simple query with each limit's term quoted in parentheses"
    );
    is( $query_cgi,  'idx=&q=title%3A%22donald%20duck%22', 'query cgi' );
    is( $query_desc, 'title:"donald duck"',                'query desc ok' );

    ( undef, $query ) = $qb->build_query_compat(
        ['AND'], ['title:"donald duck"'], undef,
        [ 'author:Dillinger Escaplan', 'mc-itype,phr:BOOK', 'mc-itype,phr:CD' ]
    );
    # Bug XXXXX: the mc-itype,phr item-type limits are routed to the nested
    # channel, so they leave the flat query_string (the author limit stays flat).
    is(
        $query->{query}{bool}{must}[0]{query_string}{query},
        '(title:"donald duck") AND author:("Dillinger Escaplan")',
        "Limits quoted correctly when passed as phrase (item type routed to nested)"
    );
    is_deeply(
        _first_nested_item_leaves($query),
        [ { terms => { 'items.itype' => [ 'BOOK', 'CD' ] } } ],
        "mc-itype,phr limits become a same-item terms clause on items.itype"
    );

    ( undef, $query ) = $qb->build_query_compat(
        ['OR'], [ 'title:"donald duck"', 'author:"Dillinger Escaplan"' ], undef,
        ['itype:BOOK']
    );
    is(
        $query->{query}{bool}{must}[0]{query_string}{query},
        '((title:"donald duck") OR (author:"Dillinger Escaplan")) AND itype:("BOOK")',
        "OR query with limit"
    );

    ( undef, $query ) = $qb->build_query_compat( undef, undef, undef, ['itype:BOOK'] );
    is(
        $query->{query}{bool}{must}[0]{query_string}{query},
        'itype:("BOOK")',
        "Limit only"
    );

    # Scan queries
    ( undef, $query, $simple_query, $query_cgi, $query_desc ) =
        $qb->build_query_compat( undef, ['new'], ['au'], undef, undef, 1 );
    is(
        $query->{query}{query_string}{query},
        '*',
        "scan query is properly formed"
    );
    is_deeply(
        $query->{aggregations}{'author'}{'terms'},
        {
            field   => 'author__facet',
            order   => { '_key' => 'asc' },
            include => '[nN][eE][wW].*'
        },
        "scan aggregation request is properly formed"
    );
    is( $query_cgi,  'idx=au&q=new&scan=1', 'query cgi' );
    is( $query_desc, 'new',                 'query desc ok' );

    ( undef, $query, $simple_query, $query_cgi, $query_desc ) =
        $qb->build_query_compat( undef, ['new'], [], undef, undef, 1 );
    is(
        $query->{query}{query_string}{query},
        '*',
        "scan query is properly formed"
    );
    is_deeply(
        $query->{aggregations}{'subject'}{'terms'},
        {
            field   => 'subject__facet',
            order   => { '_key' => 'asc' },
            include => '[nN][eE][wW].*'
        },
        "scan aggregation request is properly formed"
    );
    is( $query_cgi,  'idx=&q=new&scan=1', 'query cgi' );
    is( $query_desc, 'new',               'query desc ok' );

    my ( $limit, $limit_cgi, $limit_desc );
    ( undef, $query, $simple_query, $query_cgi, $query_desc, $limit, $limit_cgi, $limit_desc ) =
        $qb->build_query_compat(
        ['AND'], ['kw:""'], undef,
        [ 'author:Dillinger Escaplan', 'mc-itype,phr:BOOK', 'mc-itype,phr:CD' ]
        );
    # Bug XXXXX: only the flat author limit remains in $limit; the routed
    # item-type limits are described in limit_desc instead.
    is(
        $limit, 'author:("Dillinger Escaplan")',
        "Limit formed correctly when no search terms (item type routed to nested)"
    );
    is(
        $limit_cgi, '&limit=author%3ADillinger%20Escaplan&limit=mc-itype%2Cphr%3ABOOK&limit=mc-itype%2Cphr%3ACD',
        "Limit CGI formed correctly when no search terms"
    );
    is(
        $limit_desc, 'author:("Dillinger Escaplan") and Item types: BOOK and Item types: CD',
        "Limit desc formed correctly when no search terms (item types described from the nested channel)"
    );

    ( undef, $query ) = $qb->build_query_compat(
        undef, ['barcode123123'], ['ti'],
        ['acqdate,st-date-normalized= - ']
    );
    is(
        $query->{query}{bool}{must}[0]{query_string}{query},
        '(title:barcode123123*) AND date-of-acquisition.raw:[* TO *]',
        'If no date all date-of-acquisition are selected'
    );

    ( undef, $query ) = $qb->build_query_compat(
        undef, ['barcode123123'], ['ti'],
        ['acqdate,st-date-normalized=2024-08-01 - ']
    );
    is(
        $query->{query}{bool}{must}[0]{query_string}{query},
        '(title:barcode123123*) AND date-of-acquisition.raw:[2024-08-01 TO *]',
        'Open start date in date range of an st-date-normalized search is handled properly'
    );

    ( undef, $query ) = $qb->build_query_compat(
        undef, ['barcode123123'], ['ti'],
        ['acqdate,st-date-normalized= - 2024-08-30']
    );
    is(
        $query->{query}{bool}{must}[0]{query_string}{query},
        '(title:barcode123123*) AND date-of-acquisition.raw:[* TO 2024-08-30]',
        'Open end date in date range of an st-date-normalized search is handled properly'
    );

    ( undef, $query ) = $qb->build_query_compat(
        undef, ['barcode123123'], ['ti'],
        ['acqdate,st-date-normalized=2024-08-01 - 2024-08-30']
    );
    is(
        $query->{query}{bool}{must}[0]{query_string}{query},
        '(title:barcode123123*) AND date-of-acquisition.raw:[2024-08-01 TO 2024-08-30]',
        'Date range in an st-date-normalized search is handled properly'
    );
};

subtest 'build query from form subtests' => sub {
    plan tests => 5;

    my $qb = Koha::SearchEngine::Elasticsearch::QueryBuilder->new( { 'index' => 'authorities' } ),

        #when searching for authorities from a record the form returns marclist with blanks for unentered terms
        my @marclist = ( 'mainmainentry', 'mainentry', 'match', 'all' );
    my @values   = ( undef,      'Hamilton', undef,      undef );
    my @operator = ( 'contains', 'contains', 'contains', 'contains' );

    my $query = $qb->build_authorities_query_compat(
        \@marclist, undef,
        undef, \@operator, \@values, 'AUTH_TYPE', 'asc'
    );
    is( $query->{query}->{bool}->{must}[0]->{query_string}->{query}, "Hamilton*", "Expected search is populated" );
    is( scalar @{ $query->{query}->{bool}->{must} },                 1,           "Only defined search is populated" );

    @values[2] = 'Jefferson';
    $query = $qb->build_authorities_query_compat(
        \@marclist, undef,
        undef, \@operator, \@values, 'AUTH_TYPE', 'asc'
    );
    is( $query->{query}->{bool}->{must}[0]->{query_string}->{query}, "Hamilton*", "First index searched as expected" );
    is(
        $query->{query}->{bool}->{must}[1]->{query_string}->{query}, "Jefferson*",
        "Second index searched when populated"
    );
    is( scalar @{ $query->{query}->{bool}->{must} }, 2, "Only defined searches are populated" );

};

subtest 'build_query with weighted fields tests' => sub {
    plan tests => 6;

    $se->mock(
        '_load_elasticsearch_mappings',
        sub {
            return {
                authorities => {
                    Heading => {
                        label        => 'heading',
                        type         => 'string',
                        opac         => 0,
                        staff_client => 1,
                        mappings     => [
                            {
                                marc_field => '150',
                                marc_type  => 'marc21',
                            }
                        ]
                    },
                    Headingmain => {
                        label        => 'headingmain',
                        type         => 'string',
                        opac         => 1,
                        staff_client => 1,
                        mappings     => [
                            {
                                marc_field => '150',
                                marc_type  => 'marc21',
                            }
                        ]
                    }
                },
                biblios => {
                    abstract => {
                        label        => 'abstract',
                        type         => 'string',
                        opac         => 1,
                        staff_client => 0,
                        mappings     => [
                            {
                                marc_field => '520',
                                marc_type  => 'marc21',
                            }
                        ]
                    },
                    acqdate => {
                        label        => 'acqdate',
                        type         => 'string',
                        opac         => 0,
                        staff_client => 1,
                        mappings     => [
                            {
                                marc_field => '952d',
                                marc_type  => 'marc21',
                                search     => 0,
                            },
                            {
                                marc_field => '9955',
                                marc_type  => 'marc21',
                                search     => 0,
                            }
                        ]
                    },
                    title => {
                        label        => 'title',
                        type         => 'string',
                        opac         => 0,
                        staff_client => 1,
                        mappings     => [
                            {
                                marc_field => '130',
                                marc_type  => 'marc21'
                            }
                        ]
                    },
                    subject => {
                        label        => 'subject',
                        type         => 'string',
                        opac         => 0,
                        staff_client => 1,
                        mappings     => [
                            {
                                marc_field => '600a',
                                marc_type  => 'marc21'
                            }
                        ]
                    }
                }
            };
        }
    );

    my $qb = Koha::SearchEngine::Elasticsearch::QueryBuilder->new( { index => 'biblios' } );
    Koha::SearchFields->search( {} )->delete;
    Koha::SearchEngine::Elasticsearch->reset_elasticsearch_mappings();

    my $search_field;
    $search_field = Koha::SearchFields->find( { name => 'title' } );
    $search_field->update( { weight => 25.0 } );
    $search_field = Koha::SearchFields->find( { name => 'subject' } );
    $search_field->update( { weight => 15.5 } );
    Koha::SearchEngine::Elasticsearch->clear_search_fields_cache();

    my ( undef, $query ) = $qb->build_query_compat(
        undef, ['title:"donald duck"'], undef, undef,
        undef, undef, undef, { weighted_fields => 1 }
    );

    my $fields = $query->{query}{bool}{must}[0]{query_string}{fields};

    is( @{$fields}, 2, 'Search field with no searchable mappings has been excluded' );

    my @found = grep { $_ eq 'title^25.00' } @{$fields};
    is( @found, 1, 'Search field title has correct weight' );

    @found = grep { $_ eq 'subject^15.50' } @{$fields};
    is( @found, 1, 'Search field subject has correct weight' );

    ( undef, $query ) = $qb->build_query_compat(
        undef, ['title:"donald duck"'], undef, undef,
        undef, undef, undef, { weighted_fields => 1, is_opac => 1 }
    );

    $fields = $query->{query}{bool}{must}[0]{query_string}{fields};

    is_deeply(
        $fields,
        ['abstract'],
        'Only OPAC search fields are used when opac search is performed'
    );

    $qb = Koha::SearchEngine::Elasticsearch::QueryBuilder->new( { index => 'authorities' } );
    ( undef, $query ) = $qb->build_query_compat(
        undef, ['title:"donald duck"'], undef, undef,
        undef, undef, undef, { weighted_fields => 1 }
    );
    $fields = $query->{query}{bool}{must}[0]{query_string}{fields};
    is_deeply( [ sort @$fields ], [ 'heading', 'headingmain' ], 'Authorities fields retrieve for authorities index' );

    ( undef, $query ) = $qb->build_query_compat(
        undef, ['title:"donald duck"'], undef, undef,
        undef, undef, undef, { weighted_fields => 1, is_opac => 1 }
    );
    $fields = $query->{query}{bool}{must}[0]{query_string}{fields};
    is_deeply( $fields, ['headingmain'], 'Only opac authorities fields retrieved for authorities index is is_opac' );

};

subtest 'build_query_compat() SearchLimitLibrary tests' => sub {

    plan tests => 14;

    $schema->storage->txn_begin;

    my $builder = t::lib::TestBuilder->new;

    my $branch_1 = $builder->build_object( { class => 'Koha::Libraries' } );
    my $branch_2 = $builder->build_object( { class => 'Koha::Libraries' } );
    my $group    = $builder->build_object(
        {
            class => 'Koha::Library::Groups',
            value => {
                ft_search_groups_opac  => 1,
                ft_search_groups_staff => 1,
                parent_id              => undef,
                branchcode             => undef
            }
        }
    );
    my $group_1 = $builder->build_object(
        {
            class => 'Koha::Library::Groups',
            value => {
                parent_id  => $group->id,
                branchcode => $branch_1->id
            }
        }
    );
    my $group_2 = $builder->build_object(
        {
            class => 'Koha::Library::Groups',
            value => {
                parent_id  => $group->id,
                branchcode => $branch_2->id
            }
        }
    );
    my $groupid     = $group->id;
    my @branchcodes = sort { $a cmp $b } ( $branch_1->id, $branch_2->id );

    my $query_builder =
        Koha::SearchEngine::Elasticsearch::QueryBuilder->new( { index => $Koha::SearchEngine::BIBLIOS_INDEX } );

    # Bug XXXXX: branch / multibranchlimit limits are routed to the nested
    # items channel on items.homebranch / items.holdingbranch (terms), instead of
    # the flat query_string field, so they resolve on the same item. The raw
    # limit is still kept verbatim in limit_cgi for URL persistence.
    my $nested_leaf = sub {
        my ($query) = @_;
        for my $clause ( @{ $query->{query}{bool}{filter} || [] } ) {
            return $clause->{nested}{query}{bool}{filter}[0] if ref $clause eq 'HASH' && $clause->{nested};
        }
        return undef;
    };

    t::lib::Mocks::mock_preference( 'SearchLimitLibrary', 'both' );
    my ( undef, $query, undef, undef, undef, $limit, $limit_cgi, $limit_desc, undef ) =
        $query_builder->build_query_compat( undef, undef, undef, ["branch:CPL"], undef, undef, undef, undef );
    is_deeply(
        $nested_leaf->($query),
        {
            bool => {
                should => [
                    { terms => { 'items.homebranch'    => ['CPL'] } },
                    { terms => { 'items.holdingbranch' => ['CPL'] } },
                ],
                minimum_should_match => 1,
            }
        },
        "Branch limit routed to a same-item home/holding disjunction"
    );
    is( $limit_cgi, '&limit=branch%3ACPL', "Branch limit cgi is kept verbatim" );

    ( undef, $query, undef, undef, undef, $limit, $limit_cgi, $limit_desc, undef ) =
        $query_builder->build_query_compat(
        undef, undef, undef, ["multibranchlimit:$groupid"], undef, undef, undef,
        undef
        );
    is_deeply(
        $nested_leaf->($query),
        {
            bool => {
                should => [
                    { terms => { 'items.homebranch'    => \@branchcodes } },
                    { terms => { 'items.holdingbranch' => \@branchcodes } },
                ],
                minimum_should_match => 1,
            }
        },
        "Multibranch limit expanded to the group branches on home/holding"
    );
    is( $limit_cgi, "&limit=multibranchlimit%3A$groupid", "Multibranch limit cgi is kept verbatim" );
    like( $limit_desc, qr/\Q@{[ $branch_1->branchname ]}\E/, "Multibranch limit_desc lists the branch names" );
    like( $limit_desc, qr/\Q@{[ $branch_2->branchname ]}\E/, "Multibranch limit_desc lists the branch names" );

    t::lib::Mocks::mock_preference( 'SearchLimitLibrary', 'homebranch' );
    ( undef, $query, undef, undef, undef, $limit, $limit_cgi, $limit_desc, undef ) =
        $query_builder->build_query_compat( undef, undef, undef, ["branch:CPL"], undef, undef, undef, undef );
    is_deeply(
        $nested_leaf->($query), { term => { 'items.homebranch' => 'CPL' } },
        "Single-library branch limit routed to an items.homebranch term"
    );
    is( $limit_cgi, "&limit=branch%3ACPL", "limit cgi is kept verbatim" );

    ( undef, $query, undef, undef, undef, $limit, $limit_cgi, $limit_desc, undef ) =
        $query_builder->build_query_compat(
        undef, undef, undef, ["multibranchlimit:$groupid"], undef, undef, undef,
        undef
        );
    is_deeply(
        $nested_leaf->($query), { terms => { 'items.homebranch' => \@branchcodes } },
        "Multibranch limit routed to items.homebranch terms"
    );
    is( $limit_cgi, "&limit=multibranchlimit%3A$groupid", "limit cgi is kept verbatim" );

    t::lib::Mocks::mock_preference( 'SearchLimitLibrary', 'holdingbranch' );
    ( undef, $query, undef, undef, undef, $limit, $limit_cgi, $limit_desc, undef ) =
        $query_builder->build_query_compat( undef, undef, undef, ["branch:CPL"], undef, undef, undef, undef );
    is_deeply(
        $nested_leaf->($query), { term => { 'items.holdingbranch' => 'CPL' } },
        "Single-library branch limit routed to an items.holdingbranch term"
    );
    is( $limit_cgi, "&limit=branch%3ACPL", "limit cgi is kept verbatim" );

    ( undef, $query, undef, undef, undef, $limit, $limit_cgi, $limit_desc, undef ) =
        $query_builder->build_query_compat(
        undef, undef, undef, ["multibranchlimit:$groupid"], undef, undef, undef,
        undef
        );
    is_deeply(
        $nested_leaf->($query), { terms => { 'items.holdingbranch' => \@branchcodes } },
        "Multibranch limit routed to items.holdingbranch terms"
    );
    is( $limit_cgi, "&limit=multibranchlimit%3A$groupid", "limit cgi is kept verbatim" );

    $schema->storage->txn_rollback;
};

subtest 'library_limit_facet_tokens() tests (Bug XXXXX)' => sub {

    plan tests => 8;

    $schema->storage->txn_begin;

    my $builder  = t::lib::TestBuilder->new;
    my $branch_1 = $builder->build_object( { class => 'Koha::Libraries' } );
    my $branch_2 = $builder->build_object( { class => 'Koha::Libraries' } );
    my $group    = $builder->build_object(
        {
            class => 'Koha::Library::Groups',
            value => {
                ft_search_groups_opac  => 1,
                ft_search_groups_staff => 1,
                parent_id              => undef,
                branchcode             => undef
            }
        }
    );
    $builder->build_object(
        { class => 'Koha::Library::Groups', value => { parent_id => $group->id, branchcode => $branch_1->id } } );
    $builder->build_object(
        { class => 'Koha::Library::Groups', value => { parent_id => $group->id, branchcode => $branch_2->id } } );
    my $groupid = $group->id;

    my $query_builder =
        Koha::SearchEngine::Elasticsearch::QueryBuilder->new( { index => $Koha::SearchEngine::BIBLIOS_INDEX } );

    # The tokens let the UI mark a single-library facet selected even though the
    # URL keeps the raw branch: limit. They must follow SearchLimitLibrary just
    # like the query routing does. Group limits intentionally yield no tokens.
    t::lib::Mocks::mock_preference( 'SearchLimitLibrary', 'homebranch' );
    is_deeply(
        [ $query_builder->library_limit_facet_tokens('branch:CPL') ],
        ['items.homebranch:CPL'],
        "branch limit maps to the items.homebranch facet token"
    );
    is_deeply(
        [ $query_builder->library_limit_facet_tokens("multibranchlimit:$groupid") ],
        [], "a group limit yields no tokens (members are not highlighted individually)"
    );

    t::lib::Mocks::mock_preference( 'SearchLimitLibrary', 'holdingbranch' );
    is_deeply(
        [ $query_builder->library_limit_facet_tokens('branch:CPL') ],
        ['items.holdingbranch:CPL'],
        "branch limit maps to the items.holdingbranch facet token"
    );

    t::lib::Mocks::mock_preference( 'SearchLimitLibrary', 'both' );
    is_deeply(
        [ sort $query_builder->library_limit_facet_tokens('branch:CPL') ],
        [ 'items.holdingbranch:CPL', 'items.homebranch:CPL' ],
        "branch limit maps to both home and holding facet tokens"
    );

    is_deeply(
        [ $query_builder->library_limit_facet_tokens('itype:BK') ],
        [], "a non-library limit yields no tokens"
    );
    is_deeply(
        [ $query_builder->library_limit_facet_tokens('available') ],
        [], "the availability limit yields no tokens"
    );
    is_deeply(
        [ $query_builder->library_limit_facet_tokens(undef) ],
        [], "an undefined limit yields no tokens"
    );
    is_deeply(
        [ $query_builder->library_limit_facet_tokens('multibranchlimit:999999') ],
        [], "an unknown group yields no tokens"
    );

    $schema->storage->txn_rollback;
};

subtest "Handle search filters" => sub {
    plan tests => 7;

    my $qb;

    ok(
        $qb = Koha::SearchEngine::Elasticsearch::QueryBuilder->new( { 'index' => 'biblios' } ),
        'Creating new query builder object for biblios'
    );

    my $filter = Koha::SearchFilter->new(
        {
            name   => "test",
            query  => q|{"operands":["cat","bat","rat"],"indexes":["kw","ti","au"],"operators":["AND","OR"]}|,
            limits => q|{"limits":["mc-itype,phr:BK","mc-itype,phr:MU","available"]}|,
        }
    )->store;
    my $filter_id = $filter->id;

    my ( undef, undef, undef, undef, undef, $limit, $limit_cgi, $limit_desc ) =
        $qb->build_query_compat( undef, undef, undef, ["search_filter:$filter_id"] );

    is(
        $limit, q{(available:true) AND (((cat) AND title:(bat) OR author:(rat))) AND itype:(("BK") OR ("MU"))},
        "Limit correctly formed"
    );
    is( $limit_cgi, "&limit=search_filter%3A$filter_id", "CGI limit is not expanded" );
    is(
        $limit_desc, q{(available:true) AND (((cat) AND title:(bat) OR author:(rat))) AND itype:(("BK") OR ("MU"))},
        "Limit description is correctly expanded"
    );

    $filter = Koha::SearchFilter->new(
        {
            name   => "test",
            query  => q|{"operands":["su:biography"],"indexes":[],"operators":[]}|,
            limits => q|{"limits":[]}|,
        }
    )->store;
    $filter_id = $filter->id;

    ( undef, undef, undef, undef, undef, $limit, $limit_cgi, $limit_desc ) =
        $qb->build_query_compat( undef, undef, undef, ["search_filter:$filter_id"] );

    is( $limit,      q{((subject:biography))},            "Limit correctly formed for ccl type query" );
    is( $limit_cgi,  "&limit=search_filter%3A$filter_id", "CGI limit is not expanded" );
    is( $limit_desc, q{((subject:biography))},            "Limit description is correctly handled for ccl type query" );

};

subtest "_convert_sort_fields() tests" => sub {
    plan tests => 3;

    my $qb;

    ok(
        $qb = Koha::SearchEngine::Elasticsearch::QueryBuilder->new( { 'index' => 'biblios' } ),
        'Creating new query builder object for biblios'
    );

    my @sort_by = $qb->_convert_sort_fields(qw( call_number_asc author_dsc ));
    is_deeply(
        \@sort_by,
        [
            { field => 'cn-sort', direction => 'asc' },
            { field => 'author',  direction => 'desc' }
        ],
        'sort fields should have been split correctly'
    );

    # We could expect this to pass, but direction is undef instead of 'desc'
    @sort_by = $qb->_convert_sort_fields(qw( call_number_asc author_desc ));
    is_deeply(
        \@sort_by,
        [
            { field => 'cn-sort', direction => 'asc' },
            { field => 'author',  direction => 'desc' }
        ],
        'sort fields should have been split correctly'
    );
};

subtest "_sort_field() tests" => sub {
    plan tests => 5;

    my $qb;

    ok(
        $qb = Koha::SearchEngine::Elasticsearch::QueryBuilder->new( { 'index' => 'biblios' } ),
        'Creating new query builder object for biblios'
    );

    my $f = $qb->_sort_field('title');
    is(
        $f,
        'title__sort',
        'title sort mapped correctly'
    );

    $f = $qb->_sort_field('subject');
    is(
        $f,
        'subject.raw',
        'subject sort mapped correctly'
    );

    $f = $qb->_sort_field('itemnumber');
    is(
        $f,
        'itemnumber',
        'itemnumber sort mapped correctly'
    );

    $f = $qb->_sort_field('sortablenumber');
    is(
        $f,
        'sortablenumber__sort',
        'sortablenumber sort mapped correctly'
    );
};

subtest "_build_field_match_boost_query() tests" => sub {
    plan tests => 11;

    t::lib::Mocks::mock_preference( 'ElasticsearchBoostFieldMatchAmount', '0' );
    my $qb;

    ok(
        $qb = Koha::SearchEngine::Elasticsearch::QueryBuilder->new( { 'index' => 'biblios' } ),
        'Creating new query builder object for biblios'
    );

    my $field_match_boost_query = $qb->_build_field_match_boost_query( { indexes => [], operands => [] } );

    is_deeply(
        $field_match_boost_query,
        [],
        'Empty array is returned when no indexes or operands passed'
    );
    $field_match_boost_query = $qb->_build_field_match_boost_query();

    is_deeply(
        $field_match_boost_query,
        [],
        'Empty array is returned when no parameters passed'
    );

    my @indexes = ( 'kw', 'subject', 'title' );
    my @operands;
    $field_match_boost_query = $qb->_build_field_match_boost_query( { indexes => \@indexes, operands => \@operands } );
    is_deeply(
        $field_match_boost_query,
        [],
        'Empty array is returned when no parameters passed'
    );

    push @operands, "turkey";
    $field_match_boost_query = $qb->_build_field_match_boost_query( { indexes => \@indexes, operands => \@operands } );
    is_deeply(
        $field_match_boost_query,
        [ { match => { 'title-cover' => { query => 'turkey' } } } ],
        'Keyword is converted to title-cover'
    );

    push @operands, "gravy";
    $field_match_boost_query = $qb->_build_field_match_boost_query( { indexes => \@indexes, operands => \@operands } );
    is_deeply(
        $field_match_boost_query,
        [
            { match => { 'title-cover' => { query => 'turkey' } } },
            { match => { 'subject'     => { query => 'gravy' } } }
        ],
        'Subject is not converted'
    );

    push @operands, "mashed";
    $field_match_boost_query = $qb->_build_field_match_boost_query( { indexes => \@indexes, operands => \@operands } );
    is_deeply(
        $field_match_boost_query,
        [
            { match => { 'title-cover' => { query => 'turkey' } } },
            { match => { 'subject'     => { query => 'gravy' } } },
            { match => { 'title-cover' => { query => 'mashed' } } },
        ],
        'Title is not converted to title-cover'
    );

    t::lib::Mocks::mock_preference( 'ElasticsearchBoostFieldMatchAmount', '10' );
    $field_match_boost_query = $qb->_build_field_match_boost_query( { indexes => \@indexes, operands => \@operands } );
    is_deeply(
        $field_match_boost_query,
        [
            { match => { 'title-cover' => { boost => 10, query => 'turkey' } } },
            { match => { 'subject'     => { boost => 10, query => 'gravy' } } },
            { match => { 'title-cover' => { boost => 10, query => 'mashed' } } },
        ],
        'Boost is added to fields as expected only when pref has a value'
    );

    t::lib::Mocks::mock_preference( 'ElasticsearchBoostFieldMatch', '0' );
    t::lib::Mocks::mock_preference( 'QueryAutoTruncate',            '1' );
    my ( undef, $query ) = $qb->build_query_compat( ['AND'], [ 'donald duck', 'disney' ], [ 'title', 'author' ] );
    is(
        $query->{query}{bool}{must}[0]{query_string}{query},
        '(title:(donald* duck*)) AND (author:disney*)',
        'words of a multi-word term and single-word term are properly truncated'
    );
    is(
        $query->{query}{bool}{should},
        undef,
        'No should query added for boosting'
    );

    t::lib::Mocks::mock_preference( 'ElasticsearchBoostFieldMatch',       '1' );
    t::lib::Mocks::mock_preference( 'ElasticsearchBoostFieldMatchAmount', '0' );
    ( undef, $query ) = $qb->build_query_compat( ['AND'], [ 'donald duck', 'disney' ], [ 'title', 'author' ] );
    is_deeply(
        $query->{query}{bool}{should},
        [
            { match => { 'title-cover' => { query => 'donald duck' } } },
            { match => { 'author'      => { query => 'disney' } } }
        ],
        'SHould query is correctly added'
    );

};

subtest 'item filters in limit_desc and limit_cgi (Bug XXXXX)' => sub {
    plan tests => 10;

    my $builder = t::lib::TestBuilder->new;
    my $library = $builder->build_object(
        {
            class => 'Koha::Libraries',
            value => { branchname => 'My Item Filter Library' },
        }
    );
    my $itemtype = $builder->build_object(
        {
            class => 'Koha::ItemTypes',
            value => { description => 'My Item Filter Type' },
        }
    );

    my $qb = Koha::SearchEngine::Elasticsearch::QueryBuilder->new( { index => 'biblios' } );

    my ( undef, undef, undef, undef, undef, undef, $limit_cgi, $limit_desc ) =
        $qb->build_query_compat(
        undef, ['*'], undef,
        [ 'items.homebranch:' . $library->branchcode, 'items.itype:' . $itemtype->itemtype ],
        );

    # the raw items.* limits stay in limit_cgi so the facet stays active and
    # survives pagination / sorting.
    like(
        $limit_cgi, qr/limit=items\.homebranch%3A\Q@{[ $library->branchcode ]}\E/,
        'items.homebranch limit is preserved in limit_cgi'
    );
    like(
        $limit_cgi, qr/limit=items\.itype%3A\Q@{[ $itemtype->itemtype ]}\E/,
        'items.itype limit is preserved in limit_cgi'
    );

    # limit_desc shows the resolved names, not the raw codes.
    like( $limit_desc, qr/\QMy Item Filter Library\E/, 'limit_desc resolves the library code to its name' );
    like( $limit_desc, qr/\QMy Item Filter Type\E/,    'limit_desc resolves the item type code to its description' );
    unlike(
        $limit_desc, qr/items\.homebranch/,
        'limit_desc does not leak the raw items.<field> syntax'
    );

    # Availability-only filters are not part of the readable breadcrumb.
    ( undef, undef, undef, undef, undef, undef, undef, my $avail_desc ) =
        $qb->build_query_compat( undef, ['*'], undef, ['items.available:true'] );
    unlike( $avail_desc // '', qr/available/i, 'availability item filter is not described in limit_desc' );

    # the on-request user filter persists in limit_cgi and is described
    # readably in limit_desc.
    ( undef, undef, undef, undef, undef, undef, my $onreq_cgi, my $onreq_desc ) =
        $qb->build_query_compat( undef, ['*'], undef, ['items.onrequest:false'] );
    like(
        $onreq_cgi, qr/limit=items\.onrequest%3Afalse/,
        'items.onrequest limit is preserved in limit_cgi'
    );
    like( $onreq_desc // '', qr/On request: No/, 'limit_desc describes the on-request filter readably' );

    # the patron-availability user filter persists in limit_cgi and IS
    # described readably in limit_desc (unlike the staff items.available above).
    ( undef, undef, undef, undef, undef, undef, my $afp_cgi, my $afp_desc ) =
        $qb->build_query_compat( undef, ['*'], undef, ['items.available_for_patron:true'] );
    like(
        $afp_cgi, qr/limit=items\.available_for_patron%3Atrue/,
        'items.available_for_patron limit is preserved in limit_cgi'
    );
    like(
        $afp_desc // '', qr/Available for hold or reference: Yes/,
        'limit_desc describes the patron-availability filter readably'
    );
};

subtest 'advanced-search item operands and limits routed to nested (Bug XXXXX)' => sub {
    plan tests => 15;

    my $builder  = t::lib::TestBuilder->new;
    my $itemtype = $builder->build_object(
        { class => 'Koha::ItemTypes', value => { description => 'Operand Test Type' } } );

    my $qb = Koha::SearchEngine::Elasticsearch::QueryBuilder->new( { index => 'biblios' } );

    # a barcode operand (item field) AND a title operand. The barcode is
    # pulled out to the nested channel; the title stays in the query_string.
    my ( undef, $query, undef, $query_cgi, undef, undef, undef, $limit_desc ) =
        $qb->build_query_compat(
        ['AND'], [ '12345', 'foo' ], [ 'bc', 'ti' ],
        undef, undef, undef, undef, { skip_facets => 1 }
        );
    my $qstr = $query->{query}{bool}{must}[0]{query_string}{query};
    like( $qstr,   qr/foo/,    'the title operand stays in the query_string' );
    unlike( $qstr, qr/12345/,  'the barcode operand is removed from the query_string' );
    is_deeply(
        _first_nested_item_leaves($query),
        [ { term => { 'items.barcode' => '12345' } } ],
        'the barcode operand becomes a same-item nested term'
    );
    like( $limit_desc // '', qr/Barcode: 12345/, 'the routed barcode operand is described in limit_desc' );
    like( $query_cgi, qr/idx=bc/, 'the barcode operand round-trips in query_cgi' );

    # with an OR joining the rows, nothing is routed; the barcode stays
    # flat in the query_string and there is no nested item filter.
    ( undef, $query ) = $qb->build_query_compat(
        ['OR'], [ '12345', 'foo' ], [ 'bc', 'ti' ],
        undef, undef, undef, undef, { skip_facets => 1 }
    );
    like(
        $query->{query}{bool}{must}[0]{query_string}{query}, qr/barcode/,
        'with OR, the barcode operand stays in the flat query_string'
    );
    is_deeply( _first_nested_item_leaves($query), [], 'with OR, no nested item filter is built' );

    # an acquisition-date operand becomes a same-item range. As it is the
    # only operand, the text query falls back to "*".
    ( undef, $query, undef, undef, undef, undef, undef, $limit_desc ) =
        $qb->build_query_compat(
        undef, ['2020-01-01 - 2020-12-31'], ['acqdate,st-date-normalized'],
        undef, undef, undef, undef, { skip_facets => 1 }
        );
    is(
        $query->{query}{bool}{must}[0]{query_string}{query}, '*',
        'with only an item operand, the query_string falls back to *'
    );
    is_deeply(
        _first_nested_item_leaves($query),
        [ { range => { 'items.dateaccessioned' => { gte => '2020-01-01', lte => '2020-12-31' } } } ],
        'the acqdate operand becomes a same-item range on items.dateaccessioned'
    );
    like(
        $limit_desc // '', qr/\QAcquisition date: 2020-01-01 to 2020-12-31\E/,
        'the routed acqdate operand is described in limit_desc'
    );

    # the mc-itype advanced-search limit is routed to items.itype.
    ( undef, $query, undef, undef, undef, undef, my $limit_cgi, $limit_desc ) =
        $qb->build_query_compat(
        undef, ['*'], undef, [ 'mc-itype:' . $itemtype->itemtype ],
        undef, undef, undef, { skip_facets => 1 }
        );
    is_deeply(
        _first_nested_item_leaves($query),
        [ { term => { 'items.itype' => $itemtype->itemtype } } ],
        'mc-itype limit becomes a same-item nested term on items.itype'
    );
    like(
        $limit_cgi, qr/limit=mc-itype%3A\Q@{[ $itemtype->itemtype ]}\E/,
        'the raw mc-itype limit is preserved in limit_cgi'
    );
    like( $limit_desc // '', qr/\QOperand Test Type\E/, 'mc-itype limit resolves to the item type description' );

    # Empty q with only item filters: the query_string must fall back to "*" so
    # the nested filter (not an empty text query, which matches nothing) drives
    # the results -- e.g. "every item of a type in a library" without a keyword.
    ( undef, $query ) = $qb->build_query_compat(
        undef, [''], undef, [ 'mc-itype:' . $itemtype->itemtype ],
        undef, undef, undef, { skip_facets => 1 }
    );
    is(
        $query->{query}{bool}{must}[0]{query_string}{query}, '*',
        'an empty q with only item limits falls back to * so the nested filter applies'
    );
    is_deeply(
        _first_nested_item_leaves($query),
        [ { term => { 'items.itype' => $itemtype->itemtype } } ],
        'the item limit is still applied as a nested term with an empty q'
    );
};

# Return the leaf clauses of the first hard nested item filter in the query
# (any kind: term/terms/wildcard/range/...). Used by the operand-routing tests.
sub _first_nested_item_leaves {
    my ($query) = @_;
    for my $clause ( @{ $query->{query}{bool}{filter} || [] } ) {
        return $clause->{nested}{query}{bool}{filter}
            if ref $clause eq 'HASH' && $clause->{nested};
    }
    return [];
}

# Collect the term clauses of the hard nested item filter, keyed by field. Used
# when a user filter is present, in which case the auto hiding filters are
# combined with it in a single nested bool (same-item coherence).
sub _nested_item_term_filters {
    my ($query) = @_;
    my %found;
    for my $clause ( @{ $query->{query}{bool}{filter} || [] } ) {
        next unless ref $clause eq 'HASH' && $clause->{nested};
        for my $leaf ( @{ $clause->{nested}{query}{bool}{filter} || [] } ) {
            next unless $leaf->{term};
            my ($field) = keys %{ $leaf->{term} };
            $found{$field} = $leaf->{term}{$field};
        }
    }
    return \%found;
}

subtest 'OPAC item hiding filters (Bug XXXXX)' => sub {
    plan tests => 7;

    t::lib::Mocks::mock_preference( 'hidelostitems',              0 );
    t::lib::Mocks::mock_preference( 'OpacHiddenItemsHidesRecord', 0 );

    my $qb = Koha::SearchEngine::Elasticsearch::QueryBuilder->new( { index => 'biblios' } );

    # A user facet filter is present, so the hiding filters are combined with it
    # in the same nested bool: a hidden item cannot satisfy the facet either.
    my @user_limit = ('items.homebranch:CPL');

    # Intranet (no is_opac): only the user filter, no hiding filters.
    my ( undef, $query ) = $qb->build_query_compat( undef, ['*'], undef, [@user_limit] );
    my $found = _nested_item_term_filters($query);
    is( "$found->{'items.homebranch'}", 'CPL', 'user facet filter applies on the intranet' );
    ok( !exists $found->{'items.hidden_in_opac_custom'},         'no custom-hiding filter outside the OPAC' );
    ok( !exists $found->{'items.hidden_in_opac_by_preferences'}, 'no preferences-hiding filter outside the OPAC' );

    # OPAC, regular patron: user filter plus both hiding filters (false), same nested.
    ( undef, $query ) =
        $qb->build_query_compat( undef, ['*'], undef, [@user_limit], undef, 0, undef, { is_opac => 1 } );
    $found = _nested_item_term_filters($query);
    ok(
        exists $found->{'items.hidden_in_opac_custom'} && !$found->{'items.hidden_in_opac_custom'},
        'custom-hiding filter (false) combined with the user filter in the OPAC'
    );
    ok(
        exists $found->{'items.hidden_in_opac_by_preferences'} && !$found->{'items.hidden_in_opac_by_preferences'},
        'preferences-hiding filter (false) combined with the user filter in the OPAC'
    );

    # OPAC, patron whose category overrides: custom stays, preferences lifted.
    ( undef, $query ) = $qb->build_query_compat(
        undef, ['*'], undef, [@user_limit], undef, 0, undef,
        { is_opac => 1, override_hidden_items => 1 }
    );
    $found = _nested_item_term_filters($query);
    ok(
        exists $found->{'items.hidden_in_opac_custom'} && !$found->{'items.hidden_in_opac_custom'},
        'custom-hiding filter still applied for an overriding category'
    );
    ok(
        !exists $found->{'items.hidden_in_opac_by_preferences'},
        'preferences-hiding filter lifted for an overriding category'
    );
};

subtest 'OPAC record suppression (Bug XXXXX)' => sub {
    plan tests => 8;

    t::lib::Mocks::mock_preference( 'hidelostitems', 0 );

    my $qb = Koha::SearchEngine::Elasticsearch::QueryBuilder->new( { index => 'biblios' } );

    my $filter_clauses = sub { return $_[0]->{query}{bool}{filter} || []; };

    # The suppression clause is a bool.should: nested(auto) OR items_count:0.
    my $suppression = sub {
        my ($query) = @_;
        for my $clause ( @{ $filter_clauses->($query) } ) {
            return $clause if ref $clause eq 'HASH' && $clause->{bool} && $clause->{bool}{should};
        }
        return undef;
    };
    my $has_items_count_zero = sub {
        my ($query) = @_;
        my $sup = $suppression->($query) or return 0;
        return scalar grep { $_->{term} && exists $_->{term}{items_count} } @{ $sup->{bool}{should} };
    };
    my $has_hard_nested = sub {
        my ($query) = @_;
        return scalar grep { ref $_ eq 'HASH' && $_->{nested} } @{ $filter_clauses->($query) };
    };

    # OPAC, no user filter, H on: nested(auto) OR items_count:0.
    t::lib::Mocks::mock_preference( 'OpacHiddenItemsHidesRecord', 1 );
    my ( undef, $query ) = $qb->build_query_compat( undef, ['*'], undef, undef, undef, 0, undef, { is_opac => 1 } );
    my $sup = $suppression->($query);
    ok( $sup, 'a suppression bool.should clause is added (OPAC, no user filter, H on)' );
    is( $sup->{bool}{minimum_should_match}, 1, 'minimum_should_match is 1' );
    ok( $has_items_count_zero->($query), 'items_count:0 is one should clause, so item-less records still show' );
    ok(
        ( scalar grep { $_->{nested} } @{ $sup->{bool}{should} } ),
        'the auto hiding filters are the other should clause (nested)'
    );

    # OPAC, no user filter, H off: no suppression and no hard nested filter.
    t::lib::Mocks::mock_preference( 'OpacHiddenItemsHidesRecord', 0 );
    ( undef, $query ) = $qb->build_query_compat( undef, ['*'], undef, undef, undef, 0, undef, { is_opac => 1 } );
    ok( !$suppression->($query),  'no suppression clause when H is off' );
    ok( !$has_hard_nested->($query), 'no hard nested item filter without a user filter when H is off' );

    # OPAC, user filter present, H on: hard nested filter, no items_count OR.
    t::lib::Mocks::mock_preference( 'OpacHiddenItemsHidesRecord', 1 );
    ( undef, $query ) =
        $qb->build_query_compat( undef, ['*'], undef, ['items.homebranch:CPL'], undef, 0, undef, { is_opac => 1 } );
    ok( $has_hard_nested->($query),       'a hard nested item filter is used when the user filters' );
    ok( !$has_items_count_zero->($query), 'no items_count:0 OR when the user filters (item-less records hidden)' );
};

subtest 'matched-item inner_hits (Bug XXXXX)' => sub {
    plan tests => 4;

    my $qb = Koha::SearchEngine::Elasticsearch::QueryBuilder->new( { index => 'biblios' } );

    # Pull the same-item nested clause out of the assembled query.
    my $nested_of = sub {
        my ($query) = @_;
        for my $clause ( @{ $query->{query}{bool}{filter} || [] } ) {
            return $clause->{nested} if ref $clause eq 'HASH' && $clause->{nested};
        }
        return undef;
    };

    # want_matched_items on: the nested item filter carries inner_hits limited to
    # items.itemnumber, so search_compat can report the matching items.
    my ( undef, $query ) = $qb->build_query_compat(
        undef, ['*'], undef, ['items.homebranch:CPL'], undef, 0, undef,
        { want_matched_items => 1 }
    );
    my $nested = $nested_of->($query);
    ok( $nested, 'a nested item filter is assembled when the user filters' );
    is_deeply(
        $nested->{inner_hits},
        { _source => ['items.itemnumber'], size => 50000 },
        'inner_hits requested over items.itemnumber when want_matched_items is on'
    );

    # want_matched_items off: no inner_hits (default behaviour).
    ( undef, $query ) = $qb->build_query_compat( undef, ['*'], undef, ['items.homebranch:CPL'] );
    $nested = $nested_of->($query);
    ok( $nested && !exists $nested->{inner_hits}, 'no inner_hits when want_matched_items is off' );

    # want_matched_items on but no item filter: no nested, hence no inner_hits.
    ( undef, $query ) = $qb->build_query_compat(
        undef, ['donald duck'], undef, undef, undef, 0, undef,
        { want_matched_items => 1 }
    );
    ok( !$nested_of->($query), 'no nested (and no inner_hits) without item filters' );
};

$schema->storage->txn_rollback;
