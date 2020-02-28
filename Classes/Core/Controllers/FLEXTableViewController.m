//
//  FLEXTableViewController.m
//  FLEX
//
//  Created by Tanner on 7/5/19.
//  Copyright © 2019 Flipboard. All rights reserved.
//

#import "FLEXTableViewController.h"
#import "FLEXExplorerViewController.h"
#import "FLEXBookmarksViewController.h"
#import "FLEXTabsViewController.h"
#import "FLEXScopeCarousel.h"
#import "FLEXTableView.h"
#import "FLEXUtility.h"
#import "UIBarButtonItem+FLEX.h"
#import <objc/runtime.h>

@interface Block : NSObject
- (void)invoke;
@end

CGFloat const kFLEXDebounceInstant = 0.f;
CGFloat const kFLEXDebounceFast = 0.05;
CGFloat const kFLEXDebounceForAsyncSearch = 0.15;
CGFloat const kFLEXDebounceForExpensiveIO = 0.5;

@interface FLEXTableViewController ()
@property (nonatomic) NSTimer *debounceTimer;
@property (nonatomic) BOOL didInitiallyRevealSearchBar;
@property (nonatomic) UITableViewStyle style;

@property (nonatomic) BOOL hasAppeared;
@property (nonatomic, readonly) UIView *tableHeaderViewContainer;
@end

@implementation FLEXTableViewController
@synthesize tableHeaderViewContainer = _tableHeaderViewContainer;
@synthesize automaticallyShowsSearchBarCancelButton = _automaticallyShowsSearchBarCancelButton;

#pragma mark - Initialization

- (id)init {
#if FLEX_AT_LEAST_IOS13_SDK
    if (@available(iOS 13.0, *)) {
        self = [self initWithStyle:UITableViewStyleInsetGrouped];
    } else {
        self = [self initWithStyle:UITableViewStyleGrouped];
    }
#else
    self = [self initWithStyle:UITableViewStyleGrouped];
#endif
    return self;
}

- (id)initWithStyle:(UITableViewStyle)style {
    self = [super initWithStyle:style];
    
    if (self) {
        _searchBarDebounceInterval = kFLEXDebounceFast;
        _showSearchBarInitially = YES;
        _style = style;
    }
    
    return self;
}


#pragma mark - Public

- (FLEXWindow *)window {
    return (id)self.view.window;
}

- (void)setShowsSearchBar:(BOOL)showsSearchBar {
    if (_showsSearchBar == showsSearchBar) return;
    _showsSearchBar = showsSearchBar;
    
    if (showsSearchBar) {
        UIViewController *results = self.searchResultsController;
        self.searchController = [[UISearchController alloc] initWithSearchResultsController:results];
        self.searchController.searchBar.placeholder = @"Filter";
        self.searchController.searchResultsUpdater = (id)self;
        self.searchController.delegate = (id)self;
        self.searchController.dimsBackgroundDuringPresentation = NO;
        self.searchController.hidesNavigationBarDuringPresentation = NO;
        /// Not necessary in iOS 13; remove this when iOS 13 is the minimum deployment target
        self.searchController.searchBar.delegate = self;

        self.automaticallyShowsSearchBarCancelButton = YES;

        #if FLEX_AT_LEAST_IOS13_SDK
        if (@available(iOS 13, *)) {
            self.searchController.automaticallyShowsScopeBar = NO;
        }
        #endif
        
        [self addSearchController:self.searchController];
    } else {
        // Search already shown and just set to NO, so remove it
        [self removeSearchController:self.searchController];
    }
}

- (void)setShowsCarousel:(BOOL)showsCarousel {
    if (_showsCarousel == showsCarousel) return;
    _showsCarousel = showsCarousel;
    
    if (showsCarousel) {
        _carousel = ({
            __weak __typeof(self) weakSelf = self;

            FLEXScopeCarousel *carousel = [FLEXScopeCarousel new];
            carousel.selectedIndexChangedAction = ^(NSInteger idx) {
                __typeof(self) self = weakSelf;
                [self updateSearchResults:self.searchText];
            };

            // UITableView won't update the header size unless you reset the header view
            [carousel registerBlockForDynamicTypeChanges:^(FLEXScopeCarousel *carousel) {
                __typeof(self) self = weakSelf;
                [self layoutTableHeaderIfNeeded];
            }];

            carousel;
        });
        [self addCarousel:_carousel];
    } else {
        // Carousel already shown and just set to NO, so remove it
        [self removeCarousel:_carousel];
    }
}

- (NSInteger)selectedScope {
    if (self.searchController.searchBar.showsScopeBar) {
        return self.searchController.searchBar.selectedScopeButtonIndex;
    } else if (self.showsCarousel) {
        return self.carousel.selectedIndex;
    } else {
        return 0;
    }
}

- (void)setSelectedScope:(NSInteger)selectedScope {
    if (self.searchController.searchBar.showsScopeBar) {
        self.searchController.searchBar.selectedScopeButtonIndex = selectedScope;
    } else if (self.showsCarousel) {
        self.carousel.selectedIndex = selectedScope;
    }

    [self updateSearchResults:self.searchText];
}

- (NSString *)searchText {
    return self.searchController.searchBar.text;
}

- (BOOL)automaticallyShowsSearchBarCancelButton {
#if FLEX_AT_LEAST_IOS13_SDK
    if (@available(iOS 13, *)) {
        return self.searchController.automaticallyShowsCancelButton;
    }
#endif

    return _automaticallyShowsSearchBarCancelButton;
}

- (void)setAutomaticallyShowsSearchBarCancelButton:(BOOL)value {
#if FLEX_AT_LEAST_IOS13_SDK
    if (@available(iOS 13, *)) {
        self.searchController.automaticallyShowsCancelButton = value;
    }
#endif

    _automaticallyShowsSearchBarCancelButton = value;
}

- (void)updateSearchResults:(NSString *)newText { }

- (void)onBackgroundQueue:(NSArray *(^)(void))backgroundBlock thenOnMainQueue:(void(^)(NSArray *))mainBlock {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSArray *items = backgroundBlock();
        dispatch_async(dispatch_get_main_queue(), ^{
            mainBlock(items);
        });
    });
}

- (void)setsShowsShareToolbarItem:(BOOL)showsShareToolbarItem {
    _showsShareToolbarItem = showsShareToolbarItem;
    if (self.isViewLoaded) {
        [self setupToolbarItems];
    }
}

- (void)disableToolbar {
    self.navigationController.toolbarHidden = YES;
    self.navigationController.hidesBarsOnSwipe = NO;
    self.toolbarItems = nil;
}


#pragma mark - View Controller Lifecycle

- (void)loadView {
    self.view = [FLEXTableView style:self.style];
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    
    self.tableView.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
    
    // Toolbar
    self.navigationController.toolbarHidden = NO;
    self.navigationController.hidesBarsOnSwipe = YES;

    // On iOS 13, the root view controller shows it's search bar no matter what.
    // Turning this off avoids some weird flash the navigation bar does when we
    // toggle navigationItem.hidesSearchBarWhenScrolling on and off. The flash
    // will still happen on subsequent view controllers, but we can at least
    // avoid it for the root view controller
    if (@available(iOS 13, *)) {
        if (self.navigationController.viewControllers.firstObject == self) {
            _showSearchBarInitially = NO;
        }
    }
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    
    // When going back, make the search bar reappear instead of hiding
    if (@available(iOS 11.0, *)) {
        if ((self.pinSearchBar || self.showSearchBarInitially) && !self.didInitiallyRevealSearchBar) {
            self.navigationItem.hidesSearchBarWhenScrolling = NO;
        }
    }

    [self setupToolbarItems];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];

    // Allow scrolling to collapse the search bar, only if we don't want it pinned
    if (@available(iOS 11.0, *)) {
        if (self.showSearchBarInitially && !self.pinSearchBar && !self.didInitiallyRevealSearchBar) {
            // All this mumbo jumbo is necessary to work around a bug in iOS 13 up to 13.2
            // wherein quickly toggling navigationItem.hidesSearchBarWhenScrolling to make
            // the search bar appear initially results in a bugged search bar that
            // becomes transparent and floats over the screen as you scroll
            [UIView animateWithDuration:0.2 animations:^{
                self.navigationItem.hidesSearchBarWhenScrolling = YES;
                [self.navigationController.view setNeedsLayout];
                [self.navigationController.view layoutIfNeeded];
            }];
        }
    }

    // We only want to reveal the search bar when the view controller first appears.
    self.didInitiallyRevealSearchBar = YES;
}

- (void)didMoveToParentViewController:(UIViewController *)parent {
    [super didMoveToParentViewController:parent];
    // Reset this since we are re-appearing under a new
    // parent view controller and need to show it again
    self.didInitiallyRevealSearchBar = NO;
}


#pragma mark - Private

- (void)setupToolbarItems {
    UIBarButtonItem *emptySpaceOrShare = UIBarButtonItem.flex_fixedSpace;
    if (self.showsShareToolbarItem) {
        emptySpaceOrShare = FLEXBarButtonItemSystem(Action, self, @selector(shareButtonPressed));
    }
    
    self.toolbarItems = @[
        UIBarButtonItem.flex_fixedSpace,
        UIBarButtonItem.flex_flexibleSpace,
        UIBarButtonItem.flex_fixedSpace,
        UIBarButtonItem.flex_flexibleSpace,
        UIBarButtonItem.flex_fixedSpace,
        UIBarButtonItem.flex_flexibleSpace,
        emptySpaceOrShare,
        UIBarButtonItem.flex_flexibleSpace,
        FLEXBarButtonItemSystem(Bookmarks, self, @selector(showBookmarks)),
        UIBarButtonItem.flex_flexibleSpace,
        FLEXBarButtonItemSystem(Organize, self, @selector(showTabSwitcher)),
    ];
    
    // Disable tabs entirely when not presented by FLEXExplorerViewController
    UIViewController *presenter = self.navigationController.presentingViewController;
    if (![presenter isKindOfClass:[FLEXExplorerViewController class]]) {
        self.toolbarItems.lastObject.enabled = NO;
    }
}

- (void)debounce:(void(^)(void))block {
    [self.debounceTimer invalidate];
    
    self.debounceTimer = [NSTimer
        scheduledTimerWithTimeInterval:self.searchBarDebounceInterval
        target:block
        selector:@selector(invoke)
        userInfo:nil
        repeats:NO
    ];
}

- (void)layoutTableHeaderIfNeeded {
    if (self.showsCarousel) {
        self.carousel.frame = FLEXRectSetHeight(
            self.carousel.frame, self.carousel.intrinsicContentSize.height
        );
        self.carousel.frame = FLEXRectSetY(self.carousel.frame, 0);
    }
    
    self.tableView.tableHeaderView = self.tableView.tableHeaderView;
}

- (void)addCarousel:(FLEXScopeCarousel *)carousel {
    if (@available(iOS 11.0, *)) {
        self.tableView.tableHeaderView = carousel;
    } else {
        carousel.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleTopMargin;
        
        CGRect frame = self.tableHeaderViewContainer.frame;
        CGRect subviewFrame = carousel.frame;
        subviewFrame.origin.y = 0;
        
        // Put the carousel below the search bar if it's already there
        if (self.showsSearchBar) {
            carousel.frame = subviewFrame = FLEXRectSetY(
                subviewFrame, self.searchController.searchBar.frame.size.height
            );
            frame.size.height += carousel.intrinsicContentSize.height;
        } else {
            frame.size.height = carousel.intrinsicContentSize.height;
        }
        
        self.tableHeaderViewContainer.frame = frame;
        [self.tableHeaderViewContainer addSubview:carousel];
    }
    
    [self layoutTableHeaderIfNeeded];
}

- (void)removeCarousel:(FLEXScopeCarousel *)carousel {
    [carousel removeFromSuperview];
    
    if (@available(iOS 11.0, *)) {
        self.tableView.tableHeaderView = nil;
    } else {
        if (self.showsSearchBar) {
            [self removeSearchController:self.searchController];
            [self addSearchController:self.searchController];
        } else {
            self.tableView.tableHeaderView = nil;
            _tableHeaderViewContainer = nil;
        }
    }
}

- (void)addSearchController:(UISearchController *)controller {
    if (@available(iOS 11.0, *)) {
        self.navigationItem.searchController = controller;
    } else {
        controller.searchBar.autoresizingMask |= UIViewAutoresizingFlexibleBottomMargin;
        [self.tableHeaderViewContainer addSubview:controller.searchBar];
        CGRect subviewFrame = controller.searchBar.frame;
        CGRect frame = self.tableHeaderViewContainer.frame;
        frame.size.width = MAX(frame.size.width, subviewFrame.size.width);
        frame.size.height = subviewFrame.size.height;
        
        // Move the carousel down if it's already there
        if (self.showsCarousel) {
            self.carousel.frame = FLEXRectSetY(
                self.carousel.frame, subviewFrame.size.height
            );
            frame.size.height += self.carousel.frame.size.height;
        }
        
        self.tableHeaderViewContainer.frame = frame;
        [self layoutTableHeaderIfNeeded];
    }
}

- (void)removeSearchController:(UISearchController *)controller {
    if (@available(iOS 11.0, *)) {
        self.navigationItem.searchController = nil;
    } else {
        [controller.searchBar removeFromSuperview];
        
        if (self.showsCarousel) {
//            self.carousel.frame = FLEXRectRemake(CGPointZero, self.carousel.frame.size);
            [self removeCarousel:self.carousel];
            [self addCarousel:self.carousel];
        } else {
            self.tableView.tableHeaderView = nil;
            _tableHeaderViewContainer = nil;
        }
    }
}

- (UIView *)tableHeaderViewContainer {
    if (!_tableHeaderViewContainer) {
        _tableHeaderViewContainer = [UIView new];
        self.tableView.tableHeaderView = self.tableHeaderViewContainer;
    }
    
    return _tableHeaderViewContainer;
}

- (void)showBookmarks {
    UINavigationController *nav = [[UINavigationController alloc]
        initWithRootViewController:[FLEXBookmarksViewController new]
    ];
    [self presentViewController:nav animated:YES completion:nil];
}

- (void)showTabSwitcher {
    UINavigationController *nav = [[UINavigationController alloc]
        initWithRootViewController:[FLEXTabsViewController new]
    ];
    [self presentViewController:nav animated:YES completion:nil];
}

- (void)shareButtonPressed {

}


#pragma mark - Search Bar

#pragma mark UISearchResultsUpdating

- (void)updateSearchResultsForSearchController:(UISearchController *)searchController {
    [self.debounceTimer invalidate];
    NSString *text = searchController.searchBar.text;
    
    void (^updateSearchResults)() = ^{
        if (self.searchResultsUpdater) {
            [self.searchResultsUpdater updateSearchResults:text];
        } else {
            [self updateSearchResults:text];
        }
    };
    
    // Only debounce if we want to, and if we have a non-empty string
    // Empty string events are sent instantly
    if (text.length && self.searchBarDebounceInterval > kFLEXDebounceInstant) {
        [self debounce:updateSearchResults];
    } else {
        updateSearchResults();
    }
}


#pragma mark UISearchControllerDelegate

- (void)willPresentSearchController:(UISearchController *)searchController {
    // Manually show cancel button for < iOS 13
    if (!@available(iOS 13, *) && self.automaticallyShowsSearchBarCancelButton) {
        [searchController.searchBar setShowsCancelButton:YES animated:YES];
    }
}

- (void)willDismissSearchController:(UISearchController *)searchController {
    // Manually hide cancel button for < iOS 13
    if (!@available(iOS 13, *) && self.automaticallyShowsSearchBarCancelButton) {
        [searchController.searchBar setShowsCancelButton:NO animated:YES];
    }
}


#pragma mark UISearchBarDelegate

/// Not necessary in iOS 13; remove this when iOS 13 is the deployment target
- (void)searchBar:(UISearchBar *)searchBar selectedScopeButtonIndexDidChange:(NSInteger)selectedScope {
    [self updateSearchResultsForSearchController:self.searchController];
}


#pragma mark Table view

/// Not having a title in the first section looks weird with a rounded-corner table view style
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    if (@available(iOS 13, *)) {
        if (self.style == UITableViewStyleInsetGrouped) {
            return @" ";
        }
    }

    return nil; // For plain/gropued style
}

@end
