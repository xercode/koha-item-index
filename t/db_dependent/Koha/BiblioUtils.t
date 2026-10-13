#!/usr/bin/perl

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

use Test::NoWarnings;
use Test::More tests => 2;
use Test::MockModule;

use t::lib::TestBuilder;

use C4::Biblio;

use Koha::BiblioUtils;
use Koha::Database;

my $schema  = Koha::Database->new->schema;
my $builder = t::lib::TestBuilder->new;

subtest 'get_all_biblios_iterator() item_data option' => sub {
    plan tests => 3;

    $schema->storage->txn_begin;

    # Do not reach the message broker when storing the item
    my $indexer_module = Test::MockModule->new('Koha::SearchEngine::Elasticsearch::Indexer');
    $indexer_module->mock( 'index_records', sub { } );

    my $item       = $builder->build_sample_item;
    my ($item_tag) = C4::Biblio::GetMarcFromKohaField('items.itemnumber');
    my $where      = 'biblionumber = ' . $item->biblionumber;

    my $item_fields = sub {
        my $biblio = Koha::BiblioUtils->get_all_biblios_iterator( where => $where, @_ )->next;
        return scalar( my @fields = $biblio->record->field($item_tag) );
    };

    is( $item_fields->(), 1, 'the item data is embedded by default' );
    is( $item_fields->( item_data => 1 ), 1, 'the item data is embedded with item_data' );
    is( $item_fields->( item_data => 0 ), 0, 'the item data is not embedded without item_data' );

    $schema->storage->txn_rollback;
};
