import UIKit
import SystemConfiguration
import ARAnalytics
import RxSwift
import ARCollectionViewMasonryLayout
import NSObject_Rx

let HorizontalMargins = 65
let VerticalMargins = 26
let MasonryCellIdentifier = "MasonryCell"
let TableCellIdentifier = "TableCell"

class ListingsViewController: UIViewController {
    var allowAnimations = true

    var downloadImage: ListingsCollectionViewCell.DownloadImageClosure = { (url, imageView) -> () in
        if let url = url {
            imageView.sd_setImageWithURL(url)
        } else {
            imageView.image = nil
        }
    }
    var cancelDownloadImage: ListingsCollectionViewCell.CancelDownloadImageClosure = { (imageView) -> () in
        imageView.sd_cancelCurrentImageLoad()
    }

    var provider: Networking!

    lazy var viewModel: ListingsViewModelType = {
        return ListingsViewModel(provider:
            self.provider,
            selectedIndex: self.switchView.selectedIndex,
            showDetails: applyUnowned(self, ListingsViewController.showDetailsForSaleArtwork),
            presentModal: applyUnowned(self, ListingsViewController.presentModalForSaleArtwork)
        )
    }()

    var cellIdentifier = Variable(MasonryCellIdentifier)

    @IBOutlet var stagingFlag: UIImageView!
    @IBOutlet var loadingSpinner: Spinner!
    
    lazy var collectionView: UICollectionView = { return .listingsCollectionViewWithDelegateDatasource(self) }()

    lazy var switchView: SwitchView = {
        return SwitchView(buttonTitles: ListingsViewModel.SwitchValues.allSwitchValueNames())
    }()

    override func viewDidLoad() {
        super.viewDidLoad()

        // Set up development environment.

        if AppSetup.sharedState.isTesting {
            stagingFlag.hidden = true
        } else {
            if APIKeys.sharedKeys.stubResponses {
                stagingFlag.image = UIImage(named: "StubbingFlag")
            } else if detectDevelopmentEnvironment() {
                let flagImageName = AppSetup.sharedState.useStaging ? "StagingFlag" : "ProductionFlag"
                stagingFlag.image = UIImage(named: flagImageName)
            } else {
                stagingFlag.hidden = AppSetup.sharedState.useStaging == false
            }
        }


        // Add subviews

        view.addSubview(switchView)
        view.insertSubview(collectionView, belowSubview: loadingSpinner)
        
        // Set up reactive bindings
        viewModel
            .showSpinner
            .not()
            .bindTo(loadingSpinner.rx_hidden)
            .addDisposableTo(rx_disposeBag)

        // Map switch selection to cell reuse identifier.
        viewModel
            .gridSelected
            .map { gridSelected -> String in
                if gridSelected {
                    return MasonryCellIdentifier
                } else {
                    return TableCellIdentifier
                }
            }
            .bindTo(cellIdentifier)
            .addDisposableTo(rx_disposeBag)


        // Reload collection view when there is new content.
        viewModel
            .updatedContents
            .mapReplace(collectionView)
            .doOnNext { collectionView in
                collectionView.reloadData()
            }
            .dispatchAsyncMainScheduler()
            .subscribeNext { [weak self] collectionView in
                // Make sure we're on screen and not in a test or something.
                guard let _ = self?.view.window else { return }

                // Need to dispatchAsyncMainScheduler, since the changes in the CV's model aren't imediate, so we may scroll to a cell that doesn't exist yet.
                collectionView.scrollToItemAtIndexPath(NSIndexPath(forItem: 0, inSection: 0), atScrollPosition: .Top, animated: false)
            }
            .addDisposableTo(rx_disposeBag)

        // Respond to changes in layout, driven by switch selection.
        viewModel
            .gridSelected
            .map { [weak self] gridSelected -> UICollectionViewLayout in
                switch gridSelected {
                case true:
                    return ListingsViewController.masonryLayout()
                default:
                    return ListingsViewController.tableLayout(CGRectGetWidth(self?.switchView.frame ?? CGRectZero))
                }
            }
            .subscribeNext { [weak self] layout in
                // Need to explicitly call animated: false and reload to avoid animation
                self?.collectionView.setCollectionViewLayout(layout, animated: false)
            }
            .addDisposableTo(rx_disposeBag)
    }
    
    override func prepareForSegue(segue: UIStoryboardSegue, sender: AnyObject?) {
        if segue == .ShowSaleArtworkDetails {
            let saleArtwork = sender as! SaleArtwork!
            let detailsViewController = segue.destinationViewController as! SaleArtworkDetailsViewController
            detailsViewController.saleArtwork = saleArtwork
            detailsViewController.provider = provider
            ARAnalytics.event("Show Artwork Details", withProperties: ["id": saleArtwork.artwork.id])
        }
    }

    override func viewWillAppear(animated: Bool) {
        let switchHeightPredicate = "\(switchView.intrinsicContentSize().height)"
        
        switchView.constrainHeight(switchHeightPredicate)
        switchView.alignTop("\(64+VerticalMargins)", leading: "\(HorizontalMargins)", bottom: nil, trailing: "-\(HorizontalMargins)", toView: view)
        collectionView.constrainTopSpaceToView(switchView, predicate: "0")
        collectionView.alignTop(nil, leading: "0", bottom: "0", trailing: "0", toView: view)
        collectionView.contentInset = UIEdgeInsetsMake(40, 0, 80, 0)
    }
}

extension ListingsViewController {
    class func instantiateFromStoryboard(storyboard: UIStoryboard) -> ListingsViewController {
        return storyboard.viewControllerWithID(.AuctionListings) as! ListingsViewController
    }
}

// MARK: - Collection View

extension ListingsViewController: UICollectionViewDataSource, UICollectionViewDelegate, ARCollectionViewMasonryLayoutDelegate {

    func collectionView(collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        return viewModel.numberOfSaleArtworks
    }

    func collectionView(collectionView: UICollectionView, cellForItemAtIndexPath indexPath: NSIndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCellWithReuseIdentifier(cellIdentifier.value, forIndexPath: indexPath)

        if let listingsCell = cell as? ListingsCollectionViewCell {

            listingsCell.downloadImage = downloadImage
            listingsCell.cancelDownloadImage = cancelDownloadImage

            listingsCell.setViewModel(viewModel.saleArtworkViewModelAtIndexPath(indexPath))

            let bid = listingsCell.bidPressed.takeUntil(listingsCell.preparingForReuse)
            let moreInfo = listingsCell.moreInfo.takeUntil(listingsCell.preparingForReuse)

            bid
                .subscribeNext { [weak self] _ in
                    self?.viewModel.presentModalForSaleArtworkAtIndexPath(indexPath)
                }
                .addDisposableTo(rx_disposeBag)

            moreInfo
                .subscribeNext{ [weak self] _ in
                    self?.viewModel.showDetailsForSaleArtworkAtIndexPath(indexPath)
                }
                .addDisposableTo(rx_disposeBag)
        }
        
        return cell
    }

    func collectionView(collectionView: UICollectionView!, layout collectionViewLayout: ARCollectionViewMasonryLayout!, variableDimensionForItemAtIndexPath indexPath: NSIndexPath!) -> CGFloat {
        let aspectRatio = viewModel.imageAspectRatioForSaleArtworkAtIndexPath(indexPath)
        let hasEstimate = viewModel.hasEstimateForSaleArtworkAtIndexPath(indexPath)
        return MasonryCollectionViewCell.heightForCellWithImageAspectRatio(aspectRatio, hasEstimate: hasEstimate)
    }
}

// MARK: Private Methods

private extension ListingsViewController {

    func showDetailsForSaleArtwork(saleArtwork: SaleArtwork) {

        ARAnalytics.event("Artwork Details Tapped", withProperties: ["id": saleArtwork.artwork.id])
        performSegueWithIdentifier(SegueIdentifier.ShowSaleArtworkDetails.rawValue, sender: saleArtwork)
    }

    func presentModalForSaleArtwork(saleArtwork: SaleArtwork) {
        bid(viewModel.auctionID, saleArtwork: saleArtwork, allowAnimations: self.allowAnimations, provider: provider)
    }
    
    // MARK: Class methods
    
    class func masonryLayout() -> ARCollectionViewMasonryLayout {
        let layout = ARCollectionViewMasonryLayout(direction: .Vertical)
        layout.itemMargins = CGSizeMake(65, 20)
        layout.dimensionLength = CGFloat(MasonryCollectionViewCellWidth)
        layout.rank = 3
        layout.contentInset = UIEdgeInsetsMake(0.0, 0.0, CGFloat(VerticalMargins), 0.0)
        
        return layout
    }
    
    class func tableLayout(width: CGFloat) -> UICollectionViewFlowLayout {
        let layout = UICollectionViewFlowLayout()
        TableCollectionViewCell.Width = width
        layout.itemSize = CGSizeMake(width, TableCollectionViewCell.Height)
        layout.minimumLineSpacing = 0.0
        
        return layout
    }
}

// MARK: Collection view setup

extension UICollectionView {

    class func listingsCollectionViewWithDelegateDatasource(delegateDatasource: ListingsViewController) -> UICollectionView {
        let collectionView = UICollectionView(frame: CGRectZero, collectionViewLayout: ListingsViewController.masonryLayout())
        collectionView.backgroundColor = .clearColor()
        collectionView.dataSource = delegateDatasource
        collectionView.delegate = delegateDatasource
        collectionView.alwaysBounceVertical = true
        collectionView.registerClass(MasonryCollectionViewCell.self, forCellWithReuseIdentifier: MasonryCellIdentifier)
        collectionView.registerClass(TableCollectionViewCell.self, forCellWithReuseIdentifier: TableCellIdentifier)
        collectionView.allowsSelection = false
        return collectionView
    }
}
