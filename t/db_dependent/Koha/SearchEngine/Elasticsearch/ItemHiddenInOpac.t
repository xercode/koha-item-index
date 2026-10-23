#!/usr/bin/perl
#
# Copyright 2026 Xercode
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

use Test::More tests => 7;
use Test::NoWarnings;
use Test::MockModule;

use File::Basename qw( dirname );

use t::lib::Mocks;
use t::lib::Mocks::Logger;

BEGIN {
    # Mock pluginsdir and load Koha::Plugins *before* anything else can pull it
    # in (e.g. TestBuilder/Koha::Database), so the test plugins dir lands in @INC.
    my $path = dirname(__FILE__) . '/../../../../lib/plugins';
    t::lib::Mocks::mock_config( 'pluginsdir', $path );

    use_ok('Koha::Plugins');
    use_ok('Koha::Plugin::TestItemHiddenInOpac');
}

use t::lib::TestBuilder;
use Koha::Database;
use Koha::SearchEngine::Elasticsearch;

my $schema  = Koha::Database->new->schema;
my $builder = t::lib::TestBuilder->new;

subtest 'item_hidden_in_opac hook drives _item_hidden_in_opac_custom' => sub {
    plan tests => 2;

    $schema->storage->txn_begin;

    t::lib::Mocks::mock_config( 'enable_plugins', 1 );

    # Use the real test plugin, but mock plugin discovery so we don't depend on
    # the install/enable DB state and no unrelated hooks (e.g. after_item_action)
    # fire while building sample items.
    my $plugin = Koha::Plugin::TestItemHiddenInOpac->new;
    my $module = Test::MockModule->new('Koha::Plugins');
    $module->mock( 'get_enabled_plugins', sub { return ($plugin); } );

    my $es = Koha::SearchEngine::Elasticsearch->new( { index => 'biblios' } );

    my $hidden_item = $builder->build_sample_item( { itemcallnumber => 'HIDEME' } );
    my $shown_item  = $builder->build_sample_item( { itemcallnumber => 'SHOWME' } );

    is( $es->_item_hidden_in_opac_custom($hidden_item), 1, 'item hidden when the plugin vetoes it' );
    is( $es->_item_hidden_in_opac_custom($shown_item),  0, 'item not hidden when the plugin allows it' );

    $schema->storage->txn_rollback;
};

subtest 'no hiding when plugins are disabled' => sub {
    plan tests => 1;

    $schema->storage->txn_begin;

    t::lib::Mocks::mock_config( 'enable_plugins', 0 );

    my $es          = Koha::SearchEngine::Elasticsearch->new( { index => 'biblios' } );
    my $hidden_item = $builder->build_sample_item( { itemcallnumber => 'HIDEME' } );

    is(
        $es->_item_hidden_in_opac_custom($hidden_item), 0,
        'item not hidden when enable_plugins is off (call short-circuits before any plugin)'
    );

    $schema->storage->txn_rollback;
};

subtest 'restrictive: stops at the first plugin returning true' => sub {
    plan tests => 4;

    t::lib::Mocks::mock_config( 'enable_plugins', 1 );

    my $vetoes = Koha::Test::FakeHidePlugin->new(1);    # hides
    my $allows = Koha::Test::FakeHidePlugin->new(0);    # does not hide, records calls

    my $module = Test::MockModule->new('Koha::Plugins');

    # First plugin vetoes -> the second one must not be reached.
    $module->mock( 'get_enabled_plugins', sub { return ( $vetoes, $allows ); } );

    my $es = Koha::SearchEngine::Elasticsearch->new( { index => 'biblios' } );

    is( $es->_item_hidden_in_opac_custom(undef), 1, 'hidden as soon as a plugin vetoes' );
    is( $vetoes->{called},                       1, 'first (vetoing) plugin was called' );
    is( $allows->{called},                       0, 'second plugin was NOT called (short-circuit)' );

    # When the first plugin allows, iteration continues to the next one.
    $vetoes->{called} = 0;
    $allows->{called} = 0;
    $module->mock( 'get_enabled_plugins', sub { return ( $allows, $vetoes ); } );
    is( $es->_item_hidden_in_opac_custom(undef), 1, 'still hidden when a later plugin vetoes' );
};

subtest 'fails closed when a plugin dies' => sub {
    plan tests => 7;

    t::lib::Mocks::mock_config( 'enable_plugins', 1 );

    my $logger = t::lib::Mocks::Logger->new;
    my $dies   = Koha::Test::FakeHidePlugin->new('die');
    my $allows = Koha::Test::FakeHidePlugin->new(0);

    my $module = Test::MockModule->new('Koha::Plugins');
    $module->mock( 'get_enabled_plugins', sub { return ( $dies, $allows ); } );

    my $es = Koha::SearchEngine::Elasticsearch->new( { index => 'biblios' } );

    is( $es->_item_hidden_in_opac_custom(undef), 1, 'the item is hidden when a plugin dies' );
    is( $allows->{called},                       0, 'the remaining plugins are not called' );
    $logger->error_like(
        qr/^Plugin error \(Koha::Test::FakeHidePlugin\) in item_hidden_in_opac, the item is hidden in the OPAC: Broken hiding rules/,
        'the error is logged with the plugin name'
    );
    $logger->clear;

    # A plugin whose metadata cannot be read either: the plugin class is logged.
    my $broken = Koha::Test::BrokenHidePlugin->new;
    $module->mock( 'get_enabled_plugins', sub { return ($broken); } );
    is( $es->_item_hidden_in_opac_custom(undef), 1, 'the item is hidden when a plugin and its metadata die' );
    $logger->error_like(
        qr/^Plugin error \(Koha::Test::BrokenHidePlugin\) in item_hidden_in_opac/,
        'the error is logged with the plugin class'
    );
    $logger->clear;

    # A plugin that hides before the broken one: the broken one is not reached.
    my $vetoes = Koha::Test::FakeHidePlugin->new(1);
    $module->mock( 'get_enabled_plugins', sub { return ( $vetoes, $dies ); } );
    is( $es->_item_hidden_in_opac_custom(undef), 1, 'the item is hidden by the first plugin' );
    is( $logger->count('error'),                 0, 'and nothing is logged' );
};

{

    package Koha::Test::FakeHidePlugin;

    sub new {
        my ( $class, $hidden ) = @_;
        return bless { hidden => $hidden, called => 0 }, $class;
    }

    sub item_hidden_in_opac {
        my ( $self, $params ) = @_;
        $self->{called}++;
        die "Broken hiding rules\n" if $self->{hidden} eq 'die';
        return $self->{hidden};
    }

    sub get_metadata { return { name => 'Koha::Test::FakeHidePlugin' }; }
}

{

    package Koha::Test::BrokenHidePlugin;

    sub new { return bless {}, shift; }

    sub item_hidden_in_opac { die "Broken hiding rules\n"; }

    sub get_metadata { die "Broken metadata\n"; }
}
