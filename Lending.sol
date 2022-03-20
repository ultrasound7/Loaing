
pragma solidity 0.8.1;

import "./floatingPointNumber.sol";
import "./console.sol";
contract Lending is floatingPointNumber{
    using SafeMath for uint;
    using SafeMath for uint;
    ///***数据***///
    //test
    address public account1;
    address public account2;
    address public testToken1;
    address public testKtoken1 = 0x2DB0262c69324f393737b74F2f8a71D6Fda74097;
    address public testToken2;
    address public testKtoken2 = 0xe559c0f503b6de531Af733b8833749ccfAff5BE7;

    //默认为1e18的精度
    struct tokenInfo{
        uint cash;
        uint borrow;
        uint reserve;
    }
    struct ktokenInfo{
        uint totalsupply;
        uint collateralrate;
        uint blockNumber;
        uint index;
    }
    struct debt{
        uint base;
        uint index;
    }
    struct rateModel{
        uint k;
        uint b;
    }

    //合约拥有者地址
    address public  owner;
    //用户所有Ktoken地址
    address [] public allKtoken;
    //eth地址
    address public  eth;
    //weth地址
    address public  weth;
    //初始兑换率
    uint public constant INITAL_EXCHANGERATE = 1;
    //清算率 50%
    uint public constant LIQUIDITY_RATE = 5000;
    //清算奖励 110%
    uint public constant LIQUIDITY_REWARD = 11000;
    //利息中给reserver的比例 20%
    uint public constant RESERVER_RATE = 2000;
    //根据token地址得到token的cash、borrow
    mapping (address =>tokenInfo) public infoOfToken;
    //根据Ktoken地址得到Ktoken的储备情况
    mapping (address => ktokenInfo) public infoOfKtoken;
    //由token地址得到Ktoken地址
    mapping (address => address) public tokenToktoken;
    //由Ktoken地址得到token地址
    mapping (address => address) public ktokenTotoken;
    //得到用户未质押的Ktoken
    mapping (address => mapping(address => uint)) public ktokenUnlock;
    //得到用户质押的Ktoken
    mapping (address => mapping(address => uint)) public ktokenlock;
    //得到用户的Ktoken债务 ktoken => user => Debt
    mapping (address => mapping(address => debt)) public userDebt;
    //得到Ktoken的利息指数
    mapping (address => uint) public ktokenIndex;
    //得到用户所有token的地址
    mapping (address => address[]) public userKtoken;
    //标的资产的价格，模拟预言机的作用
    mapping (address => uint) public price;
    //得到Ktoken对应的利率模型
    mapping (address => rateModel) public ktokenModel;
    //检查是否 user=>ktoken
    mapping (address => bool) public ktokenExsis;

    event point1(bool _right);
    event point2(bool _right);
    event point3(uint _amount);
    event point4(uint _amount);
    event point5(debt _debt);
    ///***Owner函数***///
    constructor(address _user1,address _user2,address _token1,address _token2) {
        owner = msg.sender;
        account1 = _user1;
        account2 = _user2;
        testToken1 = _token1;
        testToken2 = _token2;
    }
    modifier onlyOwner(){
        require(msg.sender==owner,"only owner");
        _;
    }
    //设置利率模型初始参数
    function Initial(address _token,uint _amount)public onlyOwner{
        address _ktoken = tokenToktoken[_token];
        //初始K值 = 0.01
        ktokenModel[_ktoken].k = onePercent;
        ktokenModel[_ktoken].b = 0;
        // 初始index =1
        infoOfKtoken[_ktoken].index = one;
        infoOfKtoken[_ktoken].blockNumber = block.number;
        //0.5
        infoOfKtoken[_ktoken].collateralrate = 5000;
        price[_token] = _amount;
    }
    function setParameter(address _token,uint _amount,uint _k,uint _b, uint _index,uint _collateralrate)public onlyOwner{
        address _ktoken = tokenToktoken[_token];

        ktokenModel[_ktoken].k = _k;
        ktokenModel[_ktoken].b = _b;

        infoOfKtoken[_ktoken].index = _index;
        infoOfKtoken[_ktoken].collateralrate = _collateralrate;
        price[_token] = _amount;
    }
    //建立token和ktoken的映射
    function establishMapping(address _token,address _ktoken) public onlyOwner{
        tokenToktoken[_token] = _ktoken;
        ktokenTotoken[_ktoken] = _token;
    }
    function setWethAddress(address _weth) public onlyOwner{
        weth = _weth;
    }


    ///***主函数***///
    // 充值ERC20
    function externalTransferfrom(address token,uint _amount) public{
        IERC20(token).transferFrom(msg.sender,address(this),_amount);
    }
    function deposit(address _token,uint _amount) public{
        //计息
        accurateInterest(_token);
        // 根据充值token数量，通过计算兑换率，获取应该返回用户的 K token的数量
        (address _kToken,uint _KTokenAmount) = getKTokenAmount(_token,_amount);
        // 转入用户的token
        IERC20(_token).transferFrom(msg.sender,address(this),_amount);
        // 增加协议的Token的cash数量
        addCash(_token,_amount);
        // 给用户转入 K token 以及更新 Ktoken的总供应
        addKtoken(_kToken,msg.sender,_KTokenAmount);
    }
    // 充值ETH
    function depositETH() public payable{
        //计息
        accurateInterest(weth);
        //向WETH合约中存入用户发送的ETH
        IWETH(weth).deposit{value: msg.value}();
        address _kweth = tokenToktoken[weth];
        //增加WETH的cash数量
        addCash(weth,msg.value);
        // 根据充值token数量，通过计算兑换率，获取应该返回用户的 K token的数量
        (,uint _kwethAmount) = getKTokenAmount(weth,msg.value);
        // 给用户转入 K token
        addKtoken(_kweth,msg.sender,_kwethAmount);
    }
    // 取回
    function withdraw(address _ktoken,uint _amount) public{
        address _token = ktokenTotoken[_ktoken];
        //计息
        accurateInterest(_token);
        //验证用户是否有足够Ktoken
        require(ktokenUnlock[_ktoken][msg.sender]>=_amount,"user amount insuficient");
        //根据取出Ktoken的数量和兑换率得到标的资产数量
        uint _tokenAmount = _amount * getExchangeRate(_ktoken);
        //减少记录的cash值
        reduceCash(_token,_tokenAmount);
        //给用户转入标的资产
        IERC20(_token).transfer(msg.sender,_tokenAmount);
        //转出用户的Ktoken
        reduceKtoken(_ktoken,msg.sender,_amount);
    }
    // 取回WETH
    function withdrawETH(uint _amount)public {
        //计息
        accurateInterest(weth);
        address _kweth = tokenToktoken[weth];
        //验证用户是否有足够Kweth
        require(ktokenUnlock[_kweth][msg.sender]>_amount,"user amount insuficient");
        //weth数量 = Keth数量 * 兑换率
        uint _wethAmount = _amount * getExchangeRate(_kweth);
        //用WETH提取ETH
        IWETH(weth).withdraw(_wethAmount);
        //减少记录的cash值
        reduceCash(weth,_wethAmount);
        //向用户发送ETH
        //eth.call(abi.encodeWithSelector(0xa9059cbb, msg.sender, _wethAmount));
        //转出用户的Kweth
        reduceKtoken(_kweth,msg.sender,_amount);
    }
    // 借款
    function borrow(address _token,uint _amount) public{
        //计息
        accurateInterest(_token);
        address _ktoken = tokenToktoken[_token];
        //验证用户的借款能力
        require(verifyBorrowCapacity(msg.sender,_token,_amount)>=0,"insufficient borrow capacity");
        //如果cash过小，则无法通过reduceCash中的require
        reduceCash(_token,_amount);
        addBorrow(_token,_amount);
        //增加用户债务
        addDebt(_token,msg.sender,_amount);


        //给用户转入标的资产
        IERC20(_token).transfer(msg.sender,_amount);

    }
    // 借ETH
    function borrowETH(uint _amount) public{
        //计息
        accurateInterest(weth);
        //address _kweth = tokenToktoken[weth];
        //验证用户的借款能力
        require(verifyBorrowCapacity(msg.sender,weth,_amount)>=0,"insufficient borrow capacity");
        //提取ETH
        IWETH(weth).withdraw(_amount);
        //如果cash过小，则无法通过reduceCash中的require
        reduceCash(weth,_amount);
        addBorrow(weth,_amount);
        //增加用户债务
        addDebt(weth,msg.sender,_amount);
        //向用户发送ETH
        //eth.call(abi.encodeWithSelector(0xa9059cbb, msg.sender, _amount));
    }
    // 还款
    function repay(address _token,uint _amount,address _borrower) public{
        //计息
        accurateInterest(_token);

        //得到Ktoken地址
        //address Ktoken = tokenToktoken[_token];
        //用户向合约转入标的资产
        IERC20(_token).transferFrom(msg.sender,address(this),_amount);
        //
        reduceBorrow(_token,_amount);
        addCash(_token,_amount);
        emit point2(true);
        //减轻用户债务
        address _ktoken = tokenToktoken[_token];

        reduceDebt(_token,_borrower,_amount);
    }
    // 还ETH
    function repayETH(address _user)public payable{
        //计息
        accurateInterest(weth);
        //将用户发送的ETH存入WETH合约中
        IWETH(weth).deposit{value: msg.value}();
        //
        reduceBorrow(weth,msg.value);
        addCash(weth,msg.value);
        //减轻用户债务
        reduceDebt(weth,_user,msg.value);
    }
    // 清算
    function liquity(address _liquityAddress,address _borrower,address _token) public{
        //计息
        accurateInterest(_token);
        //验证borrower的净资产是否小于负债
        uint _value = verifyBorrowCapacity(msg.sender,_token,0);
        require(_value < 0 ,"enough collateral");
        //计算可以清算的标的资产数量
        (uint _tokenAmount,uint _ktokenAmount,address _ktoken) = accountLiquity(_borrower,_token);
        //为borrower偿还债务
        repay(_token,_ktokenAmount,_borrower);
        //结算清算者得到Ktoken的数量
        liquityReward(_liquityAddress,_borrower,_ktoken,_ktokenAmount);
    }
    //质押ktoken
    function lock(address _token,uint _amount)public{
        address _ktoken = tokenToktoken[_token];
        //计息
        accurateInterest(_token);
        //如果资产Ktoken不在allassert中，则添加进去
        if(ktokenExsis[_ktoken] == false){
            ktokenExsis[_ktoken] = true;
            allKtoken.push(_ktoken);
        }
        require(ktokenUnlock[_ktoken][msg.sender] >= _amount,"unlock amount insuffcient");
        addCollateral(_ktoken,msg.sender,_amount);
    }
    //解除质押ktoken
    function unlock(address _token,uint _amount)public{
        address _ktoken = tokenToktoken[_token];
        //计息
        accurateInterest(_token);

        require(ktokenlock[_ktoken][msg.sender]>=_amount,"lock amount insuffcient");
        reduceCollateral(_ktoken,msg.sender,_amount);
    }


    ///***更新***///
    /*用户存取时更新用户未质押Ktoken的值和Ktoken的总供应量
    function renewKtoken(address _ktoken,address _user,int _amount) private{
        ktokenUnlock[_ktoken][_user] += _amount;
        infoOfKtoken[_ktoken].totalsupply += _amount;
    }*/
    //转入/转出 Ktoken
    function addKtoken(address _ktoken,address _user,uint _amount) private{
        ktokenUnlock[_ktoken][_user] += _amount;
        infoOfKtoken[_ktoken].totalsupply += _amount;
    }
    function reduceKtoken(address _ktoken,address _user,uint _amount) private{
        ktokenUnlock[_ktoken][_user] -= _amount;
        infoOfKtoken[_ktoken].totalsupply -= _amount;
    }
    /*根据标的资产地址和数量，更新用户债务的base和index
    function renewDebt(address _token,address _user,uint _amount) private{
        //根据兑换率和标的资产数量得到Ktoken的数量
        address _ktoken = tokenToktoken[_token];
        uint _ktokenamount = _amount / getExchangeRate(_ktoken);
        uint _oldDebt = getOneDebtVaule()
        //debt memory new_debt;
        //更新用户债务
        debt memory old_debt = getNowDebtAmount(_user,_ktoken);
        debt memory new_debt;
        new_debt.base = old_debt.base + _ktokenamount;
        new_debt.index = ktokenIndex[_ktoken];
        userDebt[_ktoken][_user] = new_debt;
    }*/
    function addDebt(address _token,address _user,uint _amount) private{
        //根据兑换率和标的资产数量得到Ktoken的数量

        address _ktoken = tokenToktoken[_token];
        uint _ktokenAmount = _amount / getExchangeRate(_ktoken);

        //增加用户Ktoken债务：新债务 = 老债务本息合 + 借走的Ktoken数量
        uint _oldDebtAmount = getOneDebtAmount(_user,_token);

        debt memory _newDebt;
        _newDebt.base = _oldDebtAmount + _ktokenAmount;
        _newDebt.index = infoOfKtoken[_ktoken].index;
        userDebt[_ktoken][_user] = _newDebt;


    }
    function reduceDebt(address _token,address _user,uint _amount) public{
        //根据兑换率和标的资产数量得到Ktoken的数量
        address _ktoken = tokenToktoken[_token];
        (bool _success,uint _ktokenAmount) = _amount.tryDiv(getExchangeRate(_ktoken));
        require(_success == true,"div error");

        //减少用户Ktoken债务：新债务 = 老债务本息合 - 偿还的的Ktoken数量
        uint _oldDebtAmount = getOneDebtAmount(_user,_ktoken);
        require(_oldDebtAmount - _ktokenAmount>=0,"too much repay");
        console.log(_oldDebtAmount,"   ",_ktokenAmount);
        userDebt[_ktoken][_user].base = _oldDebtAmount - _ktokenAmount;
        userDebt[_ktoken][_user].index = infoOfKtoken[_ktoken].index;

    }


    ///***辅助计算函数***///
    //token和Ktoken的兑换率= (borrow+cash-reserve)/totalsupply
    function getExchangeRate(address _ktoken) public view returns(uint _exchangerate){
        address _token = ktokenTotoken[_ktoken];
        ktokenInfo memory ktokeninfo=infoOfKtoken[_ktoken];
        tokenInfo memory tokeninfo = infoOfToken[_token];
        if(ktokeninfo.totalsupply == 0){
            _exchangerate = INITAL_EXCHANGERATE;
        }
        else{
            _exchangerate =(tokeninfo.borrow + tokeninfo.cash-tokeninfo.reserve)/ktokeninfo.totalsupply;
        }
        return _exchangerate;
    }
    //得到用户当欠的Ktoken数量
    function getOneDebtAmount(address _user,address _ktoken) public view returns (uint _nowamount){



        if(userDebt[_ktoken][_user].index == 0){
            _nowamount = 0;
        }
        else{
            _nowamount = userDebt[_ktoken][_user].base * infoOfKtoken[_ktoken].index / userDebt[_ktoken][_user].index;
        }
    }
    //得到用户欠的某一ktoken价值
    function getOneDebtVaule(address _user,address _ktoken)  public view returns(uint _nowDebt){
        //得到token地址
        address _token = ktokenTotoken[_ktoken];
        //计算此时所欠的Ktoken数量
        uint _amount = getOneDebtAmount(_user,_ktoken);
        //债务 = ktoken数量 * 兑换率 * token价格
        _nowDebt = _amount * getExchangeRate(_ktoken) * price[_token];
        return _nowDebt;
    }
    //得到用户所欠的所有ktoken价值
    function getAllDebtVaule(address _user)  public view returns(uint _alldebt){
        //得到所有Ktoken
        address[] memory _allKtoken = allKtoken;
        //循环执行getOneDebtVaule函数，得到总债务
        for(uint i =0;i < _allKtoken.length;i++){
            debt memory _debt = userDebt[_allKtoken[i]][_user];
            if(_debt.base == 0) break;
            _alldebt+=getOneDebtVaule(_user,_allKtoken[i]);

        }
        return _alldebt;
    }
    // 根据转入的token数量，计算返回的kToken数量
    function getKTokenAmount(address _token,uint _amount) public view returns(address,uint){
        address _ktoken = tokenToktoken[_token];
        uint _ktokenAmount = _amount / getExchangeRate(_ktoken);
        return(_ktoken,_ktokenAmount);
    }
    //得到用户的总质押物价值
    function getUserCollateralValue(address _user)public view returns(uint _sumvalue){
        //得到用户所有Ktoken地址
        address[] memory _allKtoken = allKtoken;
        //求质押的总价值
        for(uint i = 0;i<_allKtoken.length;i++){
            //由ktoken地址得到token地址
            address _token = ktokenTotoken[_allKtoken[i]];

            //得到质押的Ktoken数量
            uint _amount = ktokenlock[_allKtoken[i]][_user];
            //总价格 = sum{Ktoken数量 * 兑换率 * token价格 * 质押率}
            _sumvalue += _amount * getExchangeRate(_allKtoken[i]) * price[_token] * infoOfKtoken[_allKtoken[i]].collateralrate /10000;

        }
        return _sumvalue;
    }
    //计算可清算最大标的资产数量
    function accountLiquity(address _borrowAddress, address _token)public view returns(uint _amount,uint _ktokenAmount,address _ktoken){
        _ktoken = tokenToktoken[_token];
        //得到Ktoken债务
        _ktokenAmount = getOneDebtAmount(_borrowAddress,_ktoken) * LIQUIDITY_RATE / 1000;
        //得到token债务
        _amount = _ktokenAmount * getExchangeRate(_ktoken);
        return(_amount,_ktokenAmount,_ktoken);
    }
    //得到token的当前借贷利率
    function getBorrowRate(address _token)public view returns(uint _borrowRate){
        address _ktoken = tokenToktoken[_token];
        uint _borrow = infoOfToken[_token].borrow;
        uint _cash = infoOfToken[_token].cash;
        uint interResult;

        // y = kx + b, x为资金利用率
        //k为18位精度  0.01 . UseRate也是18位 borrrowrate
        interResult = ktokenModel[_ktoken].k * getUseRate(_borrow,_cash);
        _borrowRate = ktokenModel[_ktoken].k * getUseRate(_borrow,_cash)  + ktokenModel[_ktoken].b;
        return _borrowRate;
    }
    //得到当前资金利用率 cash不可能是负数，所以分母不可能为0，div不作错误判断
    //为了保留输出的精度*18e
    function getUseRate(uint _borrow,uint _cash)public view returns(uint){
        if (_borrow == 0) {
            return 0;
        }
        return _borrow.mul(1e18).div(_borrow.add(_cash));
    }
    //根据区块变化和先前的利息指数得到新的利息指数
    function getNowIndex(uint _oldIndex,uint _deltaTime,address _ktoken) public view returns(uint _newIndex){
        uint _borrowRate = getBorrowRate(_ktoken);
        uint inter = _deltaTime * _borrowRate ;
        if(inter != 0){
            _newIndex = _oldIndex * inter / 1e36;
        }
        else{
            _newIndex = _oldIndex;
        }
        return _newIndex;
    }


    ///***改变状态变量的函数***///
    //根据liquidity偿还的ktoken数量，从借款者向清算者转移ktoken
    function liquityReward(address _liquidity,address _borrower,address _ktoken,uint _amount) private {
        uint _actualamount = _amount * LIQUIDITY_REWARD /1000;
        ktokenUnlock[_ktoken][_borrower]-=_actualamount;
        ktokenUnlock[_ktoken][_liquidity]+=_actualamount;
    }
    //
    function addCollateral(address _ktoken,address _user,uint _amount) private {
        ktokenlock[_ktoken][_user]+=_amount;
        ktokenUnlock[_ktoken][_user]-=_amount;
    }
    function reduceCollateral(address _ktoken,address _user,uint _amount) private {
        ktokenlock[_ktoken][_user] -= _amount;
        ktokenUnlock[_ktoken][_user] += _amount;
    }

    function addCash(address _token,uint _amount)public{
        infoOfToken[_token].cash += _amount;
    }
    function oldAddCash(address _token,uint _amount)public{
        uint _cashNow = infoOfToken[_token].cash;
        require((_cashNow + _amount) >=_amount && (_cashNow +_amount) >=_amount,"amount too big");
        infoOfToken[_token].cash += _amount;
    }
    function reduceCash(address _token,uint _amount)private{
        uint _cashNow = infoOfToken[_token].cash;
        require(_cashNow > _amount,"cash insufficient");
        infoOfToken[_token].cash -= _amount;
    }
    function addBorrow(address _token,uint _amount) private{
        uint _borrowNow = infoOfToken[_token].borrow;
        infoOfToken[_token].borrow = _borrowNow + _amount;
    }
    function reduceBorrow(address _token,uint _amount) private{
        uint _borrowNow = infoOfToken[_token].borrow;
        require(_borrowNow >= _amount,"too much");
        infoOfToken[_token].borrow -= _amount;
    }


    ///***验证函数***///
    //验证用户的（总质押物价值-总债务）>=所借金额
    function verifyBorrowCapacity(address _user,address _token,uint _amount) public view returns(uint){
        //要借的价值
        uint _borrowValue = _amount * price[_token];
        //总质押物价值
        uint _collateralValue = getUserCollateralValue(_user);
        //总债务价值
        uint _allDebt = getAllDebtVaule(_user);
        //返回净值
        return(_collateralValue - _allDebt - _borrowValue);
    }
    ///***计息***///
    function accurateInterest(address _token)public {

        //节省gas
        address _ktoken = tokenToktoken[_token];
        ktokenInfo memory _ktokenInfo = infoOfKtoken[_ktoken];
        tokenInfo memory _tokenInfo = infoOfToken[_token];

        uint _borrow = _tokenInfo.borrow;
        uint _reserve = _tokenInfo.reserve;
        uint _oldIndex =_ktokenInfo.index;

        //得到变化的区块数量
        uint _blockNumberNow = block.number;
        (bool returnMessage,uint _deltaBlock) = _blockNumberNow.trySub(_ktokenInfo.blockNumber);
        require(returnMessage == true,"deltaBlock error!");

        if(_deltaBlock != 0){
            //更新blockNumber和index
            infoOfKtoken[_ktoken].blockNumber = _blockNumberNow;
            infoOfKtoken[_ktoken].index = getNowIndex(_ktokenInfo.index,_deltaBlock,_ktoken);
            //利息 = borrow * （_newindex/_oldIndex）
            if(_borrow != 0){
                renewTokenInfo(_token,_borrow,_reserve,_ktokenInfo.index,_oldIndex);
            }

        }
        console.log("TOKEN IMFORMATION");
        console.log("borrow",_borrow);
        console.log("cash",_cash);
        console.log("index",_ktokenInfo.index);
        console.log("")


    }
    function renewTokenInfo(address _token,uint _borrow,uint _reserve,uint _index,uint _oldIndex) internal{
        uint _interest = _borrow * _index / _oldIndex;
        _reserve += _interest * RESERVER_RATE / 10000;
        _borrow += _interest * (10000 - RESERVER_RATE) / 10000;
        infoOfToken[_token].reserve = _reserve;
        infoOfToken[_token].borrow  = _borrow;
    }

    function getKtoken(address _token) public view returns(address){
        return tokenToktoken[_token];
    }

}
interface IERC20 {
    /**
     * @dev Returns the amount of tokens in existence.
     */
    function totalSupply() external view returns (uint256);

    /**
     * @dev Returns the amount of tokens owned by `account`.
     */
    function balanceOf(address account) external view returns (uint256);

    /**
     * @dev Moves `amount` tokens from the caller's account to `to`.
     *
     * Returns a boolean value indicating whether the operation succeeded.
     *
     * Emits a {Transfer} event.
     */
    function transfer(address to, uint256 amount) external returns (bool);

    /**
     * @dev Returns the remaining number of tokens that `spender` will be
     * allowed to spend on behalf of `owner` through {transferFrom}. This is
     * zero by default.
     *
     * This value changes when {approve} or {transferFrom} are called.
     */
    function allowance(address owner, address spender) external view returns (uint256);

    /**
     * @dev Sets `amount` as the allowance of `spender` over the caller's tokens.
     *
     * Returns a boolean value indicating whether the operation succeeded.
     *
     * IMPORTANT: Beware that changing an allowance with this method brings the risk
     * that someone may use both the old and the new allowance by unfortunate
     * transaction ordering. One possible solution to mitigate this race
     * condition is to first reduce the spender's allowance to 0 and set the
     * desired value afterwards:
     * https://github.com/ethereum/EIPs/issues/20#issuecomment-263524729
     *
     * Emits an {Approval} event.
     */
    function approve(address spender, uint256 amount) external returns (bool);

    /**
     * @dev Moves `amount` tokens from `from` to `to` using the
     * allowance mechanism. `amount` is then deducted from the caller's
     * allowance.
     *
     * Returns a boolean value indicating whether the operation succeeded.
     *
     * Emits a {Transfer} event.
     */
    function transferFrom(
        address from,
        address to,
        uint256 amount
    ) external returns (bool);

    /**
     * @dev Emitted when `value` tokens are moved from one account (`from`) to
     * another (`to`).
     *
     * Note that `value` may be zero.
     */
    event Transfer(address indexed from, address indexed to, uint256 value);

    /**
     * @dev Emitted when the allowance of a `spender` for an `owner` is set by
     * a call to {approve}. `value` is the new allowance.
     */
    event Approval(address indexed owner, address indexed spender, uint256 value);
}
interface IWETH {
    function deposit() external payable;
    function transfer(address to, uint value) external returns (bool);
    function withdraw(uint) external;
}
library SafeMath {
    /**
     * @dev Returns the addition of two unsigned integers, with an overflow flag.
     *
     * _Available since v3.4._
     */
    function tryAdd(uint a, uint b) internal pure returns (bool, uint) {
    unchecked {
        uint c = a + b;
        if (c < a) return (false, 0);
        return (true, c);
    }
    }

    /**
     * @dev Returns the substraction of two unsigned integers, with an overflow flag.
     *
     * _Available since v3.4._
     */
    function trySub(uint a, uint b) internal pure returns (bool, uint) {
    unchecked {
        if (b > a) return (false, 0);
        return (true, a - b);
    }
    }

    /**
     * @dev Returns the multiplication of two unsigned integers, with an overflow flag.
     *
     * _Available since v3.4._
     */
    function tryMul(uint a, uint b) internal pure returns (bool, uint) {
    unchecked {
        // Gas optimization: this is cheaper than requiring 'a' not being zero, but the
        // benefit is lost if 'b' is also tested.
        // See: https://github.com/OpenZeppelin/openzeppelin-contracts/pull/522
        if (a == 0) return (true, 0);
        uint c = a * b;
        if (c / a != b) return (false, 0);
        return (true, c);
    }
    }

    /**
     * @dev Returns the division of two unsigned integers, with a division by zero flag.
     *
     * _Available since v3.4._
     */
    function tryDiv(uint a, uint b) internal pure returns (bool, uint) {
    unchecked {
        if (b == 0) return (false, 0);
        return (true, a / b);
    }
    }

    /**
     * @dev Returns the remainder of dividing two unsigned integers, with a division by zero flag.
     *
     * _Available since v3.4._
     */
    function tryMod(uint a, uint b) internal pure returns (bool, uint) {
    unchecked {
        if (b == 0) return (false, 0);
        return (true, a % b);
    }
    }

    /**
     * @dev Returns the addition of two unsigned integers, reverting on
     * overflow.
     *
     * Counterpart to Solidity's `+` operator.
     *
     * Requirements:
     *
     * - Addition cannot overflow.
     */
    function add(uint a, uint b) internal pure returns (uint) {
        return a + b;
    }

    /**
     * @dev Returns the subtraction of two unsigned integers, reverting on
     * overflow (when the result is negative).
     *
     * Counterpart to Solidity's `-` operator.
     *
     * Requirements:
     *
     * - Subtraction cannot overflow.
     */
    function sub(uint a, uint b) internal pure returns (uint) {
        return a - b;
    }

    /**
     * @dev Returns the multiplication of two unsigned integers, reverting on
     * overflow.
     *
     * Counterpart to Solidity's `*` operator.
     *
     * Requirements:
     *
     * - Multiplication cannot overflow.
     */
    function mul(uint a, uint b) internal pure returns (uint) {
        return a * b;
    }

    /**
     * @dev Returns the integer division of two unsigned integers, reverting on
     * division by zero. The result is rounded towards zero.
     *
     * Counterpart to Solidity's `/` operator.
     *
     * Requirements:
     *
     * - The divisor cannot be zero.
     */
    function div(uint a, uint b) internal pure returns (uint) {
        return a / b;
    }

    /**
     * @dev Returns the remainder of dividing two unsigned integers. (unsigned integer modulo),
     * reverting when dividing by zero.
     *
     * Counterpart to Solidity's `%` operator. This function uses a `revert`
     * opcode (which leaves remaining gas untouched) while Solidity uses an
     * invalid opcode to revert (consuming all remaining gas).
     *
     * Requirements:
     *
     * - The divisor cannot be zero.
     */
    function mod(uint a, uint b) internal pure returns (uint) {
        return a % b;
    }

    /**
     * @dev Returns the subtraction of two unsigned integers, reverting with custom message on
     * overflow (when the result is negative).
     *
     * CAUTION: This function is deprecated because it requires allocating memory for the error
     * message unnecessarily. For custom revert reasons use {trySub}.
     *
     * Counterpart to Solidity's `-` operator.
     *
     * Requirements:
     *
     * - Subtraction cannot overflow.
     */
    function sub(
        uint a,
        uint b,
        string memory errorMessage
    ) internal pure returns (uint) {
    unchecked {
        require(b <= a, errorMessage);
        return a - b;
    }
    }

    /**
     * @dev Returns the integer division of two unsigned integers, reverting with custom message on
     * division by zero. The result is rounded towards zero.
     *
     * Counterpart to Solidity's `/` operator. Note: this function uses a
     * `revert` opcode (which leaves remaining gas untouched) while Solidity
     * uses an invalid opcode to revert (consuming all remaining gas).
     *
     * Requirements:
     *
     * - The divisor cannot be zero.
     */
    function div(
        uint a,
        uint b,
        string memory errorMessage
    ) internal pure returns (uint) {
    unchecked {
        require(b > 0, errorMessage);
        return a / b;
    }
    }

    /**
     * @dev Returns the remainder of dividing two unsigned integers. (unsigned integer modulo),
     * reverting with custom message when dividing by zero.
     *
     * CAUTION: This function is deprecated because it requires allocating memory for the error
     * message unnecessarily. For custom revert reasons use {tryMod}.
     *
     * Counterpart to Solidity's `%` operator. This function uses a `revert`
     * opcode (which leaves remaining gas untouched) while Solidity uses an
     * invalid opcode to revert (consuming all remaining gas).
     *
     * Requirements:
     *
     * - The divisor cannot be zero.
     */
    function mod(
        uint a,
        uint b,
        string memory errorMessage
    ) internal pure returns (uint) {
    unchecked {
        require(b > 0, errorMessage);
        return a % b;
    }
    }
}
